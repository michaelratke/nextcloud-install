#!/usr/bin/env bash
set -euo pipefail

a2dissite nextcloud 2>/dev/null || true
systemctl reload apache2 || true

rm -rf /var/www/nextcloud
rm -f /etc/apache2/sites-available/nextcloud.conf

mysql -uroot <<'SQL'
DROP DATABASE IF EXISTS nextcloud;
DROP USER IF EXISTS 'nc_user'@'%';
FLUSH PRIVILEGES;
SQL

crontab -u www-data -l 2>/dev/null | grep -v 'nextcloud/cron.php' | crontab -u www-data - || true

systemctl reload php8.3-fpm || true
systemctl reload apache2 || true

echo "Nextcloud-Instanz entfernt. Apache/MariaDB/Redis bleiben installiert."
