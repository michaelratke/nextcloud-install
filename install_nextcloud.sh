#!/usr/bin/env bash
set -euo pipefail

########################################
# === Konfiguration anpassen ===
########################################
NC_DOMAIN="cloud.example.com"     # öffentliche Domain (über OPNsense/Nginx)
BACKEND_HOST="10.0.0.50"          # IP/Host der Ubuntu-VM (Apache-Backend)
PROXY_IP="10.0.0.1"               # OPNsense/Nginx-Proxy-IP (ggf. weitere später ergänzen)

NC_WEBROOT="/var/www/nextcloud"
DB_HOST="localhost"
DB_NAME="nextcloud"
DB_USER="nc_user"
DB_PASS="${DB_PASS:-$(openssl rand -base64 24)}"   # kann extern via ENV vorgegeben werden

NC_ADMIN_USER="admin"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-$(openssl rand -base64 18)}"

PHP_VER="8.3"

CRED_FILE="/root/nextcloud_credentials.txt"

########################################
# Root-Check
########################################
if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen (sudo -i)."
  exit 1
fi

########################################
# Helfer
########################################
restart_php_apache() {
  systemctl reload "php${PHP_VER}-fpm" || systemctl restart "php${PHP_VER}-fpm" || true
  systemctl reload apache2 || systemctl restart apache2 || true
}

log_creds() {
  {
    echo "==== Nextcloud Install-Credentials ===="
    echo "Datum: $(date -Is)"
    echo "Domain: https://${NC_DOMAIN}"
    echo "Backend: http://${BACKEND_HOST}"
    echo "DB_HOST=${DB_HOST}"
    echo "DB_NAME=${DB_NAME}"
    echo "DB_USER=${DB_USER}"
    echo "DB_PASS=${DB_PASS}"
    echo "ADMIN_USER=${NC_ADMIN_USER}"
    echo "ADMIN_PASS=${NC_ADMIN_PASS}"
    echo
  } | tee -a "$CRED_FILE" >/dev/null
  chmod 600 "$CRED_FILE"
}

########################################
# System aktualisieren & Pakete
########################################
apt update
apt -y full-upgrade

apt -y install \
  apache2 libapache2-mod-fcgid \
  "php${PHP_VER}" "php${PHP_VER}-fpm" "php${PHP_VER}-mysql" \
  "php${PHP_VER}-gd" "php${PHP_VER}-mbstring" "php${PHP_VER}-intl" \
  "php${PHP_VER}-xml" "php${PHP_VER}-zip" "php${PHP_VER}-curl" \
  "php${PHP_VER}-bcmath" "php${PHP_VER}-gmp" \
  php-imagick "php${PHP_VER}-apcu" "php${PHP_VER}-redis" \
  mariadb-server redis-server unzip bzip2 jq curl gnupg2

a2enmod proxy proxy_fcgi setenvif headers rewrite env dir mime
a2enconf "php${PHP_VER}-fpm"

systemctl enable --now "php${PHP_VER}-fpm" apache2 redis-server mariadb

########################################
# MariaDB: DB & User anlegen (idempotent)
########################################
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

########################################
# PHP/OPcache/Upload-Tuning
########################################
PHP_INI_CLI="/etc/php/${PHP_VER}/cli/php.ini"
PHP_INI_FPM="/etc/php/${PHP_VER}/fpm/php.ini"
for INI in "$PHP_INI_CLI" "$PHP_INI_FPM"; do
  sed -ri 's/^;?opcache.enable=.*/opcache.enable=1/' "$INI"
  sed -ri 's/^;?opcache.enable_cli=.*/opcache.enable_cli=1/' "$INI"
  sed -ri 's/^;?opcache.memory_consumption=.*/opcache.memory_consumption=192/' "$INI"
  sed -ri 's/^;?opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/' "$INI"
  sed -ri 's/^;?opcache.max_accelerated_files=.*/opcache.max_accelerated_files=20000/' "$INI"
  sed -ri 's/^;?opcache.validate_timestamps=.*/opcache.validate_timestamps=1/' "$INI"
  sed -ri 's/^;?opcache.revalidate_freq=.*/opcache.revalidate_freq=60/' "$INI"
  sed -ri 's/^;?memory_limit =.*/memory_limit = 512M/' "$INI"
  sed -ri 's/^;?upload_max_filesize =.*/upload_max_filesize = 2G/' "$INI"
  sed -ri 's/^;?post_max_size =.*/post_max_size = 2G/' "$INI"
  sed -ri 's/^;?max_execution_time =.*/max_execution_time = 360/' "$INI"
done
restart_php_apache

########################################
# Nextcloud Download + Verify (robust)
########################################
mkdir -p /tmp/nc-dl
cd /tmp/nc-dl

curl -fLO https://download.nextcloud.com/server/releases/latest.tar.bz2
curl -fLO https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256

# Die Zeile mit "latest.tar.bz2" greifen (z.T. enthält die .sha256 mehrere Zeilen)
REMOTE_HASH="$(grep 'latest.tar.bz2' latest.tar.bz2.sha256 | awk '{print $1}')"
LOCAL_HASH="$(sha256sum latest.tar.bz2 | awk '{print $1}')"

if [ -z "$REMOTE_HASH" ] || [ "$REMOTE_HASH" != "$LOCAL_HASH" ]; then
  echo "Fehler: Checksum-Mismatch oder kein Hash gefunden."
  echo "Remote: $REMOTE_HASH"
  echo "Local : $LOCAL_HASH"
  exit 1
fi
echo "Checksum OK"

tar -xjf latest.tar.bz2

########################################
# Webroot bereitstellen (idempotent)
########################################
# vHost anlegen/aktualisieren
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

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    Header always set Referrer-Policy "no-referrer"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    # HSTS darf auch hier gesetzt sein – wir terminieren TLS vor dem Backend
    Header always set Strict-Transport-Security "max-age=15768000; includeSubDomains; preload"

    Timeout 300
</VirtualHost>
EOF

a2dissite 000-default 2>/dev/null || true
a2ensite nextcloud
systemctl reload apache2

# Nextcloud-Dateien platzieren (idempotent)
if [ -d "$NC_WEBROOT" ] && [ -f "$NC_WEBROOT/version.php" ]; then
  echo "Nextcloud-Verzeichnis existiert bereits – Dateien werden nicht überschrieben."
else
  rm -rf "$NC_WEBROOT"
  mv /tmp/nc-dl/nextcloud "$NC_WEBROOT"
fi

# Rechte
chown -R www-data:www-data "${NC_WEBROOT}"
find "${NC_WEBROOT}" -type d -exec chmod 750 {} \;
find "${NC_WEBROOT}" -type f -exec chmod 640 {} \;

########################################
# Installation nur ausführen, wenn noch nicht installiert
########################################
if sudo -u www-data php "${NC_WEBROOT}/occ" status 2>/dev/null | grep -q "installed: true"; then
  echo "Nextcloud ist bereits installiert – Installationsschritt wird übersprungen."
else
  log_creds

  sudo -u www-data php "${NC_WEBROOT}/occ" maintenance:install \
    --database "mysql" \
    --database-name "${DB_NAME}" \
    --database-user "${DB_USER}" \
    --database-pass "${DB_PASS}" \
    --admin-user "${NC_ADMIN_USER}" \
    --admin-pass "${NC_ADMIN_PASS}"
fi

########################################
# Nextcloud Tuning & Proxy-Settings (idempotent)
########################################
# Caches
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set memcache.local --value '\OC\Memcache\APCu'
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set memcache.locking --value '\OC\Memcache\Redis'
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set redis --value '{"host":"127.0.0.1","port":6379}' --type json

# Trusted Domains
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set trusted_domains 1 --value="${NC_DOMAIN}" || true
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set trusted_domains 2 --value="${BACKEND_HOST}" || true

# Proxy/Overwrite
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set overwrite.cli.url --value="https://${NC_DOMAIN}"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set overwritehost --value="${NC_DOMAIN}"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set overwriteprotocol --value="https"
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set trusted_proxies 0 --value="${PROXY_IP}"

# Sonstiges
sudo -u www-data php "${NC_WEBROOT}/occ" config:system:set default_phone_region --value="DE" || true
sudo -u www-data php "${NC_WEBROOT}/occ" background:cron

# Cron einrichten (alle 5 Min) – idempotent
CRONLINE="*/5 * * * * php -f ${NC_WEBROOT}/cron.php"
( crontab -u www-data -l 2>/dev/null | grep -v "${NC_WEBROOT}/cron.php" ; echo "${CRONLINE}" ) | crontab -u www-data -

restart_php_apache

echo "====================================================="
echo "Installation abgeschlossen."
echo "Domain (über OPNsense/Nginx):  https://${NC_DOMAIN}"
echo "Backend (Apache HTTP):         http://${BACKEND_HOST}"
echo "Credentials gespeichert unter: ${CRED_FILE}"
echo "Hinweis: Trage im OPNsense/Nginx den Upstream => ${BACKEND_HOST}:80 ein."
echo "====================================================="
