#!/usr/bin/env bash
set -euo pipefail

############################
# === Konfiguration ===
############################
# Deine öffentliche Domain (über OPNSense/Nginx/ACME erreichbar)
NC_DOMAIN="cloud.meine-domain.com"

# Interne IP/Hostname der Ubuntu-VM (Apache-Backend), auf die OPNSense weiterleitet
BACKEND_HOST="10.0.0.10"

# OPNSense-/Proxy-IP, die als trusted_proxy eingetragen wird
PROXY_IP="10.0.0.1"

# Nextcloud Pfade
NC_WEBROOT="/var/www/nextcloud"

# DB-Einstellungen
DB_HOST="localhost"
DB_NAME="nextcloud"
DB_USER="nc_user"
DB_PASS="$(openssl rand -base64 24)"

# Nextcloud Admin
NC_ADMIN_USER="admin"
NC_ADMIN_PASS="$(openssl rand -base64 18)"

# PHP-Version (Ubuntu 24.04 = 8.3)
PHP_VER="8.3"

############################
# === System-Updates ===
############################
apt update
apt -y full-upgrade

############################
# === Pakete installieren ===
############################
# Apache + PHP-FPM + Extensions + MariaDB + Redis + Tools
apt -y install \
  apache2 libapache2-mod-fcgid \
  "php${PHP_VER}-fpm" "php${PHP_VER}" \
  "php${PHP_VER}-gd" "php${PHP_VER}-mbstring" "php${PHP_VER}-intl" \
  "php${PHP_VER}-xml" "php${PHP_VER}-zip" "php${PHP_VER}-curl" \
  "php${PHP_VER}-bcmath" "php${PHP_VER}-gmp" \
  "php${PHP_VER}-imagick" "php${PHP_VER}-apcu" "php${PHP_VER}-redis" \
  mariadb-server redis-server unzip bzip2 jq curl gnupg2

# Apache-Module
a2enmod proxy proxy_fcgi setenvif headers rewrite env dir mime
a2enconf "php${PHP_VER}-fpm"

systemctl enable --now php${PHP_VER}-fpm
systemctl enable --now apache2
systemctl enable --now redis-server
systemctl enable --now mariadb

############################
# === MariaDB-DB & User ===
############################
# Sichere DB-Passwörter schon gesetzt? – wir setzen nur die NC-spezifische DB an
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

############################
# === PHP/OPcache/APCu Tuning ===
############################
PHP_INI_CLI="/etc/php/${PHP_VER}/cli/php.ini"
PHP_INI_FPM="/etc/php/${PHP_VER}/fpm/php.ini"
for INI in "$PHP_INI_CLI" "$PHP_INI_FPM"; do
  sed -ri 's/^;?opcache.enable=.*/opcache.enable=1/' "$INI"
  sed -ri 's/^;?opcache.enable_cli=.*/opcache.enable_cli=1/' "$INI"
  sed -ri 's/^;?opcache.memory_consumption=.*/opcache.memory_consumption=192/' "$INI"
  sed -ri 's/^;?opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/' "$INI"
  sed -ri 's/^;?opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$INI"
  sed -ri 's/^;?opcache.validate_timestamps=.*/opcache.validate_timestamps=1/' "$INI"
  sed -ri 's/^;?opcache.revalidate_freq=.*/opcache.revalidate_freq=60/' "$INI"
  sed -ri 's/^;?memory_limit =.*/memory_limit = 512M/' "$INI"
  sed -ri 's/^;?upload_max_filesize =.*/upload_max_filesize = 2G/' "$INI"
  sed -ri 's/^;?post_max_size =.*/post_max_size = 2G/' "$INI"
  sed -ri 's/^;?max_execution_time =.*/max_execution_time = 360/' "$INI"
done
systemctl restart php${PHP_VER}-fpm

############################
# === Nextcloud holen ===
############################
cd /tmp
curl -LO https://download.nextcloud.com/server/releases/latest.tar.bz2
curl -LO https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256sum
sha256sum -c latest.tar.bz2.sha256sum
tar -xjf latest.tar.bz2
rm -rf "${NC_WEBROOT}"
mv nextcloud "${NC_WEBROOT}"

# Rechte
chown -R www-data:www-data "${NC_WEBROOT}"
find "${NC_WEBROOT}" -type d -exec chmod 750 {} \;
find "${NC_WEBROOT}" -type f -exec chmod 640 {} \;

############################
# === Apache vHost (HTTP-Backend) ===
############################
cat >/etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName ${NC_DOMAIN}
    ServerAlias ${BACKEND_HOST}
    DocumentRoot ${NC_WEBROOT}

    <Directory ${NC_WEBROOT}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    # PHP-FPM via Proxy (empfohlen)
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    # Wichtige Header (Backend bleibt HTTP – SSL macht OPNSense/Nginx)
    Header always set Referrer-Policy "no-referrer"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Strict-Transport-Security "max-age=15768000; includeSubDomains; preload"

    # Empfohlen für große Uploads/Downloads
    Timeout 300
</VirtualHost>
EOF

a2dissite 000-default || true
a2ensite nextcloud
systemctl reload apache2

############################
# === Nextcloud CLI-Install ===
############################
# Occ benötigt Schreibrechte im Webroot – bereits gesetzt.
sudo -u www-data php "${NC_WEBROOT}/occ" maintenance:install \
  --database "mysql" \
  --database-name "${DB_NAME}" \
  --database-user "${DB_USER}" \
  --database-pass "${DB_PASS}" \
  --admin-user "${NC_ADMIN_USER}" \
  --admin-pass "${NC_ADMIN_PASS}"

############################
# === Nextcloud Tuning & Proxy-Settings ===
############################
# APCu lokal + Redis für Locking
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set memcache.local --value '\OC\Memcache\APCu'
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set memcache.locking --value '\OC\Memcache\Redis'
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set redis --value '{"host":"127.0.0.1","port":6379}' --type json

# Trusted domains: Domain + Backend-Host
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set trusted_domains 1 --value="${NC_DOMAIN}"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set trusted_domains 2 --value="${BACKEND_HOST}"

# Proxy: wir terminieren HTTPS am OPNSense, daher Overwrite & Trusted Proxy setzen
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set overwrite.cli.url --value="https://${NC_DOMAIN}"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set overwritehost --value="${NC_DOMAIN}"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set overwriteprotocol --value="https"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set trusted_proxies 0 --value="${PROXY_IP}"

# Empfohlene Nextcloud-Settings
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set default_phone_region --value="DE"
sudo -u www-data php "${NC_WEBROOT}/occ" background:cron

############################
# === Systemd Cronjob für Nextcloud ===
############################
# Cronjob alle 5 Minuten
CRONLINE="*/5 * * * * php -f ${NC_WEBROOT}/cron.php"
( crontab -u www-data -l 2>/dev/null | grep -v "${NC_WEBROOT}/cron.php" ; echo "${CRONLINE}" ) | crontab -u www-data -

############################
# === Output ===
############################
echo "====================================================="
echo "Nextcloud wurde installiert."
echo "Domain:            https://${NC_DOMAIN}  (über OPNSense/Nginx)"
echo "Backend (Apache):  http://${BACKEND_HOST}"
echo "DB Name:           ${DB_NAME}"
echo "DB User:           ${DB_USER}"
echo "DB Pass:           ${DB_PASS}"
echo "Admin User:        ${NC_ADMIN_USER}"
echo "Admin Pass:        ${NC_ADMIN_PASS}"
echo "WICHTIG: Trage im OPNSense/Nginx-Proxy das Backend => ${BACKEND_HOST}:80 ein."
echo "====================================================="
