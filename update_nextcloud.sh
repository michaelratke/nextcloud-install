#!/usr/bin/env bash
set -euo pipefail

# === Pfade anpassen ===
NC_ROOT="/var/www/nextcloud"
PHP_BIN="/usr/bin/php"
OCC="$PHP_BIN $NC_ROOT/occ"
UPD="$PHP_BIN $NC_ROOT/updater/updater.phar"

# === Backup-Ziele ===
TS="$(date +%F_%H%M%S)"
BK_DIR="/root/backup-nextcloud/$TS"
DB_NAME="nextcloud"
DB_USER="nc_user"
DB_HOST="localhost"
# DB-Passwort aus der config lesen:
DB_PASS="$(php -r 'include "'$NC_ROOT'/config/config.php"; echo $CONFIG["dbpassword"];')"

mkdir -p "$BK_DIR"

echo "==> Wartungsmodus EIN"
sudo -u www-data $OCC maintenance:mode --on

echo "==> Backup: Webroot (ohne data) & config"
tar -C /var/www -czf "$BK_DIR/webroot.tar.gz" --exclude='nextcloud/data' nextcloud

echo "==> Backup: Datenverzeichnis"
tar -C "$NC_ROOT" -czf "$BK_DIR/data.tar.gz" data

echo "==> Backup: Datenbankdump"
mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --single-transaction --quick "$DB_NAME" | gzip > "$BK_DIR/db.sql.gz"

echo "==> Integrierten Updater starten"
sudo -u www-data $UPD --no-interaction

echo "==> Datenbank-Migrationen/Repair"
sudo -u www-data $OCC upgrade
sudo -u www-data $OCC maintenance:repair || true
sudo -u www-data $OCC db:add-missing-indices || true
sudo -u www-data $OCC db:convert-filecache-bigint --no-interaction || true

echo "==> PHP-FPM/Apache neu laden"
systemctl reload php8.3-fpm || true
systemctl reload apache2 || true

echo "==> Wartungsmodus AUS"
sudo -u www-data $OCC maintenance:mode --off

echo "==> Fertig. Backups liegen in: $BK_DIR"
