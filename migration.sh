#!/bin/bash
# CloudPanel migration script (Ubuntu 18+)
# - Parallel export+copy (throttled)
# - Sequential site create, rsync, FTP/cron setup, DB create/import

set -o pipefail

# --------------------------------------------------------------------
# Config / Paths
# --------------------------------------------------------------------
LOGFILE="/tmp/clp_migration_debug.log"
CREDENTIALS_FILE="/tmp/credentials.log"

# SSH details for the *remote* CloudPanel server
ssh_user="<SSH_USER>"
ssh_host="<SSH_HOST>"
ssh_pass="<SSH_PASSWORD>"
ssh_port="<SSH_PORT>"   # e.g., 4209 or 22

# Remote/local SQLite DB paths
remote_db_path="/home/clp/htdocs/app/data/db.sq3"
local_copy_path="/tmp/db_remote_copy.sq3"      # Remote DB pulled here
local_db_path="/home/clp/htdocs/app/data/db.sq3"  # Local CloudPanel DB

# Concurrency for export+copy jobs
MAX_JOBS=${MAX_JOBS:-3}
STATUS_DIR="/tmp/migrate_status"

# --------------------------------------------------------------------
# Ensure tools are installed
# --------------------------------------------------------------------
need_pkg() {
  if ! command -v "$1" &>/dev/null; then
    echo "$1 is not installed. Installing $1..." | tee -a "$LOGFILE"
    sudo apt-get update -y && sudo apt-get install -y "$1"
  fi
}
need_pkg sshpass
need_pkg sqlite3
need_pkg rsync
need_pkg openssl

# --------------------------------------------------------------------
# Common SSH/SCP/RSYNC options (non-interactive, custom port, safer)
# --------------------------------------------------------------------
SSH_OPTS="-p $ssh_port -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
SCP_OPTS="-P $ssh_port -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
RSYNC_SSH="ssh -p $ssh_port -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

# --------------------------------------------------------------------
# Secure credentials file
# --------------------------------------------------------------------
: > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"

# --------------------------------------------------------------------
# Step 4: Copy remote SQLite DB locally
# --------------------------------------------------------------------
echo "Connecting to remote and copying database file..." | tee -a "$LOGFILE"
sshpass -p "$ssh_pass" scp $SCP_OPTS "$ssh_user@$ssh_host:$remote_db_path" "$local_copy_path"
if [ $? -ne 0 ]; then
  echo "Failed to copy remote SQLite DB. Check SSH details/permissions." | tee -a "$LOGFILE"
  exit 1
fi
echo "Database file copied to $local_copy_path." | tee -a "$LOGFILE"

# --------------------------------------------------------------------
# Step 5: List PHP sites from remote DB copy
# --------------------------------------------------------------------
echo "Listing PHP sites from remote DB copy..." | tee -a "$LOGFILE"
php_sites=$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, s.user_password, p.php_version
FROM site s
JOIN php_settings p ON s.id = p.site_id
WHERE s.type = 'php';")

if [ -z "$php_sites" ]; then
  echo "No PHP sites found in remote DB copy." | tee -a "$LOGFILE"
  exit 1
fi

# --------------------------------------------------------------------
# Step 6–13: For each PHP site, create site, copy nginx/ssl, rsync content,
#            create FTP users, add cron jobs (SEQUENTIAL)
# --------------------------------------------------------------------
# Ensure ftp-user group exists (for ProFTPD setups that use it)
if ! getent group ftp-user >/dev/null; then
  groupadd ftp-user
fi

while IFS="|" read -r site_id domain_name site_user site_password php_version; do
  echo "Processing site_id=$site_id domain=$domain_name" | tee -a "$LOGFILE"

  # Fallbacks
  [ -z "$php_version" ] && php_version="7.4"
  [ -z "$site_user" ] && site_user="defaultuser"
  [ -z "$site_password" ] && site_password="defaultpassword"

  # Create PHP site
  echo "Creating site: $domain_name (PHP $php_version) ..." | tee -a "$LOGFILE"
  clpctl site:add:php \
    --domainName="$domain_name" \
    --phpVersion="$php_version" \
    --vhostTemplate="Generic" \
    --siteUser="$site_user" \
    --siteUserPassword="$site_password" 2>&1 | tee -a "$LOGFILE"
  if [ $? -ne 0 ]; then
    echo "Failed to create site $domain_name. Skipping." | tee -a "$LOGFILE"
    echo "--------------------------------------" | tee -a "$LOGFILE"
    continue
  fi
  echo "Site $domain_name created." | tee -a "$LOGFILE"

  # Get local site ID
  local_site_id=$(sqlite3 "$local_db_path" "SELECT id FROM site WHERE domain_name = '$domain_name';")
  echo "Local site_id for $domain_name is $local_site_id." | tee -a "$LOGFILE"

  # vhost_template from remote DB → local DB
  echo "Fetching vhost_template for $domain_name..." | tee -a "$LOGFILE"
  vhost_template=$(sqlite3 "$local_copy_path" "
SELECT vhost_template FROM site WHERE domain_name = '$domain_name';")

  if [ -n "$vhost_template" ]; then
    cleaned_vhost_template=$(echo "$vhost_template" | sed "s/'/''/g")
    sqlite3 "$local_db_path" "UPDATE site SET vhost_template = '$cleaned_vhost_template' WHERE domain_name = '$domain_name';"
    if [ $? -eq 0 ]; then
      echo "Updated vhost_template for $domain_name." | tee -a "$LOGFILE"
    else
      echo "Failed to update vhost_template for $domain_name." | tee -a "$LOGFILE"
    fi
  else
    echo "No vhost_template found in remote DB for $domain_name. Skipping update." | tee -a "$LOGFILE"
  fi

  # application + varnish_cache
  echo "Fetching 'application' and 'varnish_cache' for $domain_name..." | tee -a "$LOGFILE"
  app_varnish=$(sqlite3 "$local_copy_path" "
SELECT application || '|' || varnish_cache FROM site WHERE domain_name = '$domain_name';")
  IFS="|" read -r application varnish_cache <<< "$app_varnish"

  if [ -n "$application" ] || [ -n "$varnish_cache" ]; then
    escaped_application=$(echo "$application" | sed "s/'/''/g")
    [ -z "$escaped_application" ] && application="NULL" || application="'$escaped_application'"
    [ -z "$varnish_cache" ] && varnish_cache="NULL"

    sqlite3 "$local_db_path" "UPDATE site SET application = $application, varnish_cache = $varnish_cache WHERE id = $local_site_id;"
    if [ $? -eq 0 ]; then
      echo "Updated application/varnish_cache for $domain_name." | tee -a "$LOGFILE"
    else
      echo "Failed to update application/varnish_cache for $domain_name." | tee -a "$LOGFILE"
    fi
  else
    echo "No application/varnish_cache found for $domain_name." | tee -a "$LOGFILE"
  fi

  # Copy nginx conf
  echo "Copying Nginx conf for $domain_name..." | tee -a "$LOGFILE"
  remote_nginx_conf="/etc/nginx/sites-enabled/$domain_name.conf"
  local_nginx_conf="/etc/nginx/sites-enabled/$domain_name.conf"
  sshpass -p "$ssh_pass" scp $SCP_OPTS "$ssh_user@$ssh_host:$remote_nginx_conf" "$local_nginx_conf"
  if [ $? -eq 0 ]; then
    echo "Nginx conf copied for $domain_name." | tee -a "$LOGFILE"
  else
    echo "Failed to copy Nginx conf for $domain_name." | tee -a "$LOGFILE"
  fi

  # Copy SSL certs dir
  echo "Copying SSL certificate files for $domain_name..." | tee -a "$LOGFILE"
  remote_ssl_cert_dir="/etc/nginx/ssl-certificates/"
  local_ssl_cert_dir="/etc/nginx/ssl-certificates/"
  sshpass -p "$ssh_pass" rsync -avz --progress -e "$RSYNC_SSH" "$ssh_user@$ssh_host:$remote_ssl_cert_dir" "$local_ssl_cert_dir"
  if [ $? -eq 0 ]; then
    echo "SSL certificates copied." | tee -a "$LOGFILE"
  else
    echo "Failed to copy SSL certificates." | tee -a "$LOGFILE"
  fi

  # Rsync site content
  echo "Rsyncing site content for $domain_name..." | tee -a "$LOGFILE"
  remote_site_dir="/home/$site_user/htdocs/$domain_name/"
  local_site_dir="/home/$site_user/htdocs/$domain_name/"
  if [ ! -d "$local_site_dir" ]; then
    echo "Creating directory $local_site_dir" | tee -a "$LOGFILE"
    mkdir -p "$local_site_dir"
    chown "$site_user:$site_user" "$local_site_dir"
  fi
  sshpass -p "$ssh_pass" rsync -avz --progress -e "$RSYNC_SSH" "$ssh_user@$ssh_host:$remote_site_dir" "$local_site_dir"
  if [ $? -eq 0 ]; then
    echo "Site content copied for $domain_name." | tee -a "$LOGFILE"
  else
    echo "Failed to copy site content for $domain_name." | tee -a "$LOGFILE"
  fi

  # Create FTP users from remote DB
  ftp_users=$(sqlite3 "$local_copy_path" "
SELECT user_name, home_directory FROM ftp_user WHERE site_id = $site_id;")

  if [ -n "$ftp_users" ]; then
    echo "$ftp_users" | while IFS="|" read -r ftp_user_name ftp_home_directory; do
      ftp_password=$(openssl rand -base64 12)
      echo "Creating FTP user $ftp_user_name ($domain_name)..." | tee -a "$LOGFILE"

      # Create system user + home
      id -u "$ftp_user_name" &>/dev/null || adduser --disabled-password --home "$ftp_home_directory" --gecos "" "$ftp_user_name"
      echo "$ftp_user_name:$ftp_password" | chpasswd

      mkdir -p "$ftp_home_directory"
      chown "$site_user:$site_user" "$ftp_home_directory"

      # Group assignments
      usermod -aG "$site_user" "$ftp_user_name"
      usermod -aG ftp-user "$ftp_user_name"

      echo "FTP User: $ftp_user_name, Password: $ftp_password, Home: $ftp_home_directory" | tee -a "$CREDENTIALS_FILE"

      # Insert FTP user into local CP DB
      current_time=$(date '+%Y-%m-%d %H:%M:%S')
      escaped_ftp_user_name=$(echo "$ftp_user_name" | sed "s/'/''/g")
      escaped_ftp_home_directory=$(echo "$ftp_home_directory" | sed "s/'/''/g")
      sqlite3 "$local_db_path" "INSERT INTO ftp_user (site_id, created_at, updated_at, user_name, home_directory)
        VALUES ($local_site_id, '$current_time', '$current_time', '$escaped_ftp_user_name', '$escaped_ftp_home_directory');"
      if [ $? -eq 0 ]; then
        echo "Inserted FTP user $ftp_user_name into local DB." | tee -a "$LOGFILE"
      else
        echo "Failed to insert FTP user $ftp_user_name into local DB." | tee -a "$LOGFILE"
      fi
    done

    echo "Restarting ProFTPD..." | tee -a "$LOGFILE"
    sudo systemctl restart proftpd
    if [ $? -eq 0 ]; then
      echo "ProFTPD restarted." | tee -a "$LOGFILE"
    else
      echo "Failed to restart ProFTPD." | tee -a "$LOGFILE"
    fi
  else
    echo "No FTP users for $domain_name." | tee -a "$LOGFILE"
  fi

  # Cron jobs
  cron_jobs=$(sqlite3 "$local_copy_path" "
    SELECT c.minute, c.hour, c.day, c.month, c.weekday, c.command
    FROM cron_job c
    WHERE c.site_id = $site_id;")

  if [ -n "$cron_jobs" ]; then
    cron_file="/etc/cron.d/$site_user"
    : > "$cron_file"
    echo "$cron_jobs" | while IFS="|" read -r minute hour day month weekday command; do
      echo "$minute $hour $day $month $weekday $command" >> "$cron_file"
      current_time=$(date '+%Y-%m-%d %H:%M:%S')
      escaped_minute=$(echo "$minute" | sed "s/'/''/g")
      escaped_hour=$(echo "$hour" | sed "s/'/''/g")
      escaped_day=$(echo "$day" | sed "s/'/''/g")
      escaped_month=$(echo "$month" | sed "s/'/''/g")
      escaped_weekday=$(echo "$weekday" | sed "s/'/''/g")
      escaped_command=$(echo "$command" | sed "s/'/''/g")
      sqlite3 "$local_db_path" "INSERT INTO cron_job (site_id, created_at, updated_at, minute, hour, day, month, weekday, command)
        VALUES ($local_site_id, '$current_time', '$current_time', '$escaped_minute', '$escaped_hour', '$escaped_day', '$escaped_month', '$escaped_weekday', '$escaped_command');"
      if [ $? -eq 0 ]; then
        echo "Inserted cron job for $domain_name into local DB." | tee -a "$LOGFILE"
      else
        echo "Failed to insert cron job for $domain_name into local DB." | tee -a "$LOGFILE"
      fi
    done
    chmod 644 "$cron_file"
    echo "Cron jobs written to $cron_file." | tee -a "$LOGFILE"
  else
    echo "No cron jobs for $domain_name." | tee -a "$LOGFILE"
  fi

  echo "--------------------------------------" | tee -a "$LOGFILE"
done < <(echo "$php_sites")

# --------------------------------------------------------------------
# Step 14–15: PHP sites with MySQL DBs
# --------------------------------------------------------------------
echo "Listing PHP sites with MySQL databases..." | tee -a "$LOGFILE"
php_sites_mysql=$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, d.name AS db_name, du.user_name AS db_user
FROM site s
JOIN database d ON s.id = d.site_id
JOIN database_user du ON d.id = du.database_id
WHERE s.type = 'php';")

echo "Fetched PHP Sites with MySQL Databases:" | tee -a "$LOGFILE"
echo "$php_sites_mysql" | tee -a "$LOGFILE"

if [ -z "$php_sites_mysql" ]; then
  echo "No PHP+MySQL sites found. Exiting." | tee -a "$LOGFILE"
  exit 0
fi

# --------------------------------------------------------------------
# Parallel export+copy (Step 16–17) with throttling (Ubuntu 18+ safe)
# --------------------------------------------------------------------
mkdir -p "$STATUS_DIR"

export SSH_PASS="$ssh_pass" SSH_USER="$ssh_user" SSH_HOST="$ssh_host" SSH_PORT="$ssh_port"
export LOGFILE STATUS_DIR
export RSYNC_SSH SSH_OPTS SCP_OPTS

run_export_and_copy() {
  local domain_name="$1"
  local site_user="$2"
  local db_name="$3"

  local remote_backup_dir="/home/$site_user/backups"
  local remote_sql_file="${remote_backup_dir}/${db_name}.sql.gz"
  local status_file="$STATUS_DIR/${db_name}.status"

  {
    echo "[${domain_name}] Starting export for DB: ${db_name}..."

    # Remote export (non-interactive)
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS -n "$SSH_USER@$SSH_HOST" \
      "mkdir -p '$remote_backup_dir' && clpctl db:export --databaseName='$db_name' --file='$remote_sql_file'"
    rc1=$?
    if [ $rc1 -ne 0 ]; then
      echo "[${domain_name}] EXPORT FAILED (rc=$rc1)"
      echo "FAIL export" > "$status_file"
      exit 1
    fi
    echo "[${domain_name}] Export complete. Copying..."

    # Copy gz dump to local
    sshpass -p "$SSH_PASS" scp $SCP_OPTS < /dev/null \
      "$SSH_USER@$SSH_HOST:$remote_sql_file" "/tmp/${db_name}.sql.gz"
    rc2=$?
    if [ $rc2 -ne 0 ]; then
      echo "[${domain_name}] COPY FAILED (rc=$rc2)"
      echo "FAIL copy" > "$status_file"
      exit 1
    fi

    echo "[${domain_name}] Export+Copy SUCCESS"
    echo "OK" > "$status_file"
  } | tee -a "$LOGFILE"
}
export -f run_export_and_copy

# Throttle helper (Bash 4.4+ supports wait -n; fallback to polling)
have_wait_n=0
if bash -c 'wait -n 2>/dev/null' 2>/dev/null; then
  have_wait_n=1
fi

throttle() {
  if [ "$have_wait_n" -eq 1 ]; then
    while [ "$(jobs -pr | wc -l)" -ge "$MAX_JOBS" ]; do
      wait -n
    done
  else
    while [ "$(jobs -pr | wc -l)" -ge "$MAX_JOBS" ]; do
      sleep 0.5
    done
  fi
}

echo "Starting parallel export+copy jobs (max $MAX_JOBS)..." | tee -a "$LOGFILE"
while IFS="|" read -r _ domain_name site_user db_name _; do
  throttle
  run_export_and_copy "$domain_name" "$site_user" "$db_name" &
done < <(echo "$php_sites_mysql")

# Drain remaining jobs
if [ "$have_wait_n" -eq 1 ]; then
  while [ -n "$(jobs -pr)" ]; do
    wait -n
  done
else
  wait
fi

# Check statuses
fail_count=0
while IFS="|" read -r _ _ _ db_name _; do
  status_file="$STATUS_DIR/${db_name}.status"
  if [ ! -f "$status_file" ] || ! grep -q "^OK$" "$status_file"; then
    echo "Export/copy failed for DB: $db_name — will SKIP import." | tee -a "$LOGFILE"
    fail_count=$((fail_count+1))
  fi
done < <(echo "$php_sites_mysql")

if [ $fail_count -gt 0 ]; then
  echo "$fail_count database(s) failed in export/copy. See $STATUS_DIR and $LOGFILE." | tee -a "$LOGFILE"
fi

# --------------------------------------------------------------------
# Step 18–20: Create DBs and import dumps (SEQUENTIAL)
# --------------------------------------------------------------------
echo "Creating databases and importing dumps..." | tee -a "$LOGFILE"

while IFS="|" read -r _ domain_name site_user db_name db_user; do
  status_file="$STATUS_DIR/${db_name}.status"
  if [ ! -f "$status_file" ] || ! grep -q "^OK$" "$status_file"; then
    echo "Skipping import for $db_name due to failed export/copy." | tee -a "$LOGFILE"
    echo "--------------------------------------" | tee -a "$LOGFILE"
    continue
  fi

  echo "Setting up DB for site: $domain_name (DB: $db_name, User: $db_user)" | tee -a "$LOGFILE"

  # Random password
  db_password=$(openssl rand -base64 12)

  # Create DB
  echo "Creating database $db_name for $domain_name..." | tee -a "$LOGFILE"
  clpctl db:add \
    --domainName="$domain_name" \
    --databaseName="$db_name" \
    --databaseUserName="$db_user" \
    --databaseUserPassword="$db_password" 2>&1 | tee -a "$LOGFILE"

  if [ $? -ne 0 ]; then
    echo "Failed to create DB $db_name for $domain_name. Skipping import." | tee -a "$LOGFILE"
    echo "--------------------------------------" | tee -a "$LOGFILE"
    continue
  fi

  # Log credentials
  {
    echo "Database credentials for $domain_name:"
    echo "DB Name: $db_name, DB User: $db_user, DB Password: $db_password"
  } | tee -a "$CREDENTIALS_FILE" >/dev/null

  # Import dump
  local_sql_file="/tmp/${db_name}.sql.gz"
  if [ -f "$local_sql_file" ]; then
    echo "Importing dump for $db_name..." | tee -a "$LOGFILE"
    clpctl db:import --databaseName="$db_name" --file="$local_sql_file" 2>&1 | tee -a "$LOGFILE"
    if [ $? -eq 0 ]; then
      echo "Import OK for $db_name." | tee -a "$LOGFILE"
    else
      echo "Import FAILED for $db_name." | tee -a "$LOGFILE"
    fi
  } else
    echo "Dump file not found: $local_sql_file. Skipping import for $db_name." | tee -a "$LOGFILE"
  fi

  echo "Finished DB setup for site: $domain_name" | tee -a "$LOGFILE"
  echo "--------------------------------------" | tee -a "$LOGFILE"
done < <(echo "$php_sites_mysql")

# --------------------------------------------------------------------
# Step 22: Completion
# --------------------------------------------------------------------
echo "All done. Migration completed at $(date)" | tee -a "$LOGFILE"
echo "See credentials in $CREDENTIALS_FILE (permissions 600)." | tee -a "$LOGFILE"
