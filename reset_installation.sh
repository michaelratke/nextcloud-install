#!/usr/bin/env bash

# Apache-Site deaktivieren & neu laden
sudo a2dissite nextcloud 2>/dev/null || true
sudo systemctl reload apache2

# Webroot löschen
sudo rm -rf /var/www/nextcloud

# Cron-Eintrag für www-data (Nextcloud-Cron) entfernen
sudo crontab -u www-data -l 2>/dev/null | grep -v 'nextcloud/cron.php' | sudo crontab -u www-data - || true

# DB & DB-User löschen (nur wenn du sicher bist!)
mysql -uroot <<'SQL'
DROP DATABASE IF EXISTS nextcloud;
DROP USER IF EXISTS 'nc_user'@'%';
FLUSH PRIVILEGES;
SQL

# Apache vHost-Datei entfernen
sudo rm -f /etc/apache2/sites-available/nextcloud.conf

# PHP-FPM & Apache neu laden
sudo systemctl reload php8.3-fpm || true
sudo systemctl reload apache2 || true
