#!/usr/bin/env bash
# CloudPanel multi-site migration – Ubuntu 18+ compatible
# - Sequential site provisioning, content sync, FTP users, cron
# - Parallel (throttled) DB export+copy
# - Sequential DB create+import
# - Optional Laravel .env update after import

set -Eeuo pipefail
umask 077
trap 'echo "[ERROR] Line $LINENO exited with status $?" | tee -a "$LOGFILE"' ERR

# --------------------------------------------------------------------
# Config / Paths
# --------------------------------------------------------------------
LOGFILE="/tmp/clp_migration_debug.log"
CREDENTIALS_FILE="/tmp/credentials.log"

# Remote CloudPanel SSH details (can be exported as env)
ssh_user="${SSH_USER:-<SSH_USER>}"
ssh_host="${SSH_HOST:-<SSH_HOST>}"
ssh_pass="${SSH_PASS:-<SSH_PASSWORD>}"
ssh_port="${SSH_PORT:-22}"  # e.g., 4209 or 22

# Remote/local SQLite DB paths
remote_db_path="/home/clp/htdocs/app/data/db.sq3"
local_copy_path="/tmp/db_remote_copy.sq3"              # pulled remote DB copy
local_db_path="/home/clp/htdocs/app/data/db.sq3"       # local CloudPanel DB

# Parallelism for export+copy phase
MAX_JOBS="${MAX_JOBS:-3}"
STATUS_DIR="/tmp/migrate_status"

# --------------------------------------------------------------------
# Utilities
# --------------------------------------------------------------------
log() { echo -e "$@" | tee -a "$LOGFILE"; }

ensure_pkgs() {
  local pkgs=()
  for p in sshpass sqlite3 rsync openssl gzip; do
    command -v "$p" &>/dev/null || pkgs+=("$p")
  done
  if ((${#pkgs[@]})); then
    log "Installing packages: ${pkgs[*]}"
    sudo apt-get update -y >>"$LOGFILE" 2>&1
    sudo apt-get install -y "${pkgs[@]}" >>"$LOGFILE" 2>&1
  fi
}
ensure_pkgs

# Consistent non-interactive SSH/SCP/RSYNC options
SSH_OPTS=(-p "$ssh_port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
SCP_OPTS=(-P "$ssh_port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
RSYNC_SSH=("ssh" -p "$ssh_port" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10)

# Secure creds file / status dir
: > "$CREDENTIALS_FILE"; chmod 600 "$CREDENTIALS_FILE"
mkdir -p "$STATUS_DIR"

# Ensure ftp-user group (if ProFTPD uses it)
if ! getent group ftp-user >/dev/null; then
  log "Creating group ftp-user"
  sudo groupadd ftp-user
fi

# --------------------------------------------------------------------
# Helpers to update Laravel .env safely
# --------------------------------------------------------------------
update_dotenv_var() {
  local key=$1 val=$2 file=$3
  # escape backslashes for awk
  local esc_val
  esc_val=$(printf '%s' "$val" | sed -e 's/\\/\\\\/g')
  awk -v K="$key" -v V="$esc_val" '
    BEGIN{done=0}
    $0 ~ "^"K"=" { print K"="V; done=1; next }
    { print }
    END{ if (!done) print K"="V }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

update_laravel_credentials() {
  local env_path=$1
  local db_name=$2
  local db_user=$3
  local db_password=$4
  local domain=$5

  log "Updating Laravel .env for $domain"
  cp "$env_path" "${env_path}.backup.$(date +%Y%m%d_%H%M%S)"
  update_dotenv_var "DB_DATABASE" "$db_name" "$env_path"
  update_dotenv_var "DB_USERNAME" "$db_user" "$env_path"
  update_dotenv_var "DB_PASSWORD" "$db_password" "$env_path"
  log "Laravel credentials updated for $domain"
}

# --------------------------------------------------------------------
# Step 1: Pull remote SQLite DB copy
# --------------------------------------------------------------------
log "Copying remote CloudPanel SQLite DB..."
sshpass -p "$ssh_pass" scp "${SCP_OPTS[@]}" "$ssh_user@$ssh_host:$remote_db_path" "$local_copy_path" >>"$LOGFILE" 2>&1
log "Remote DB copied to $local_copy_path"

# --------------------------------------------------------------------
# Step 2: Enumerate PHP sites from remote DB copy
# --------------------------------------------------------------------
log "Enumerating PHP sites from remote DB copy..."
php_sites="$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, s.user_password, p.php_version
FROM site s
JOIN php_settings p ON s.id = p.site_id
WHERE s.type = 'php';
")"

if [[ -z "${php_sites// }" ]]; then
  log "No PHP sites found in remote DB. Exiting."
  exit 0
fi

# --------------------------------------------------------------------
# Step 3: Create/prepare each site (SEQUENTIAL)
# --------------------------------------------------------------------
while IFS="|" read -r site_id domain_name site_user site_password php_version; do
  log "\n=== Processing site_id=$site_id domain=$domain_name ==="

  # Fallbacks
  [[ -z "${php_version// }" ]] && php_version="7.4"
  [[ -z "${site_user// }"    ]] && site_user="defaultuser"
  [[ -z "${site_password// }" ]] && site_password="defaultpassword"

  # Idempotency: check if site exists locally
  local_site_id="$(sqlite3 "$local_db_path" "SELECT id FROM site WHERE domain_name = '$domain_name';")" || true
  if [[ -n "${local_site_id// }" ]]; then
    log "Site $domain_name already exists locally with id=$local_site_id. Skipping creation."
  else
    log "Creating site $domain_name (PHP $php_version)..."
    clpctl site:add:php \
      --domainName="$domain_name" \
      --phpVersion="$php_version" \
      --vhostTemplate="Generic" \
      --siteUser="$site_user" \
      --siteUserPassword="$site_password" >>"$LOGFILE" 2>&1
    local_site_id="$(sqlite3 "$local_db_path" "SELECT id FROM site WHERE domain_name = '$domain_name';")"
    log "Site created. Local id=$local_site_id"
  fi

  # vhost_template from remote → local
  vhost_template="$(sqlite3 "$local_copy_path" "
SELECT vhost_template FROM site WHERE domain_name = '$domain_name';
")" || true
  if [[ -n "${vhost_template// }" ]]; then
    cleaned_vhost_template="$(printf "%s" "$vhost_template" | sed "s/'/''/g")"
    sqlite3 "$local_db_path" "UPDATE site SET vhost_template = '$cleaned_vhost_template' WHERE domain_name = '$domain_name';" >>"$LOGFILE" 2>&1
    log "Updated vhost_template for $domain_name"
  else
    log "No vhost_template found for $domain_name in remote DB copy"
  fi

  # application + varnish_cache
  app_varnish="$(sqlite3 "$local_copy_path" "
SELECT application || '|' || varnish_cache FROM site WHERE domain_name = '$domain_name';
")" || true
  IFS="|" read -r application varnish_cache <<< "$app_varnish"
  if [[ -n "${application// }" || -n "${varnish_cache// }" ]]; then
    esc_app="$(printf "%s" "$application" | sed "s/'/''/g")"
    [[ -z "${esc_app// }" ]] && app_sql="NULL" || app_sql="'$esc_app'"
    [[ -z "${varnish_cache// }" ]] && varnish_sql="NULL" || varnish_sql="$varnish_cache"
    sqlite3 "$local_db_path" "UPDATE site SET application = $app_sql, varnish_cache = $varnish_sql WHERE id = $local_site_id;" >>"$LOGFILE" 2>&1
    log "Updated application/varnish_cache for $domain_name"
  else
    log "No application/varnish_cache for $domain_name"
  fi

  # Copy nginx conf
  log "Copying Nginx conf for $domain_name..."
  remote_nginx_conf="/etc/nginx/sites-enabled/$domain_name.conf"
  local_nginx_conf="/etc/nginx/sites-enabled/$domain_name.conf"
  sshpass -p "$ssh_pass" scp "${SCP_OPTS[@]}" "$ssh_user@$ssh_host:$remote_nginx_conf" "$local_nginx_conf" >>"$LOGFILE" 2>&1 || log "WARN: Nginx conf copy failed for $domain_name"

  # Copy SSL cert dir
  log "Syncing SSL certificates dir..."
  remote_ssl_cert_dir="/etc/nginx/ssl-certificates/"
  local_ssl_cert_dir="/etc/nginx/ssl-certificates/"
  sshpass -p "$ssh_pass" rsync -avz --delete --progress -e "${RSYNC_SSH[*]}" \
    "$ssh_user@$ssh_host:$remote_ssl_cert_dir" "$local_ssl_cert_dir" >>"$LOGFILE" 2>&1 || log "WARN: SSL sync failed"

  # Rsync site content
  log "Rsync site content for $domain_name..."
  remote_site_dir="/home/$site_user/htdocs/$domain_name/"
  local_site_dir="/home/$site_user/htdocs/$domain_name/"
  if [[ ! -d "$local_site_dir" ]]; then
    mkdir -p "$local_site_dir"
    chown "$site_user:$site_user" "$local_site_dir"
  fi
  sshpass -p "$ssh_pass" rsync -avz --delete --progress -e "${RSYNC_SSH[*]}" \
    "$ssh_user@$ssh_host:$remote_site_dir" "$local_site_dir" >>"$LOGFILE" 2>&1 || log "WARN: Content rsync failed"

  # FTP users (idempotent insert)
  ftp_users="$(sqlite3 "$local_copy_path" "
SELECT user_name, home_directory FROM ftp_user WHERE site_id = $site_id;
")" || true

  if [[ -n "${ftp_users// }" ]]; then
    while IFS="|" read -r ftp_user_name ftp_home_directory; do
      [[ -z "${ftp_user_name// }" ]] && continue
      [[ -z "${ftp_home_directory// }" ]] && ftp_home_directory="/home/$ftp_user_name"

      if id -u "$ftp_user_name" &>/dev/null; then
        log "FTP user $ftp_user_name exists — ensuring groups and home"
      else
        ftp_password="$(openssl rand -base64 12)"
        log "Creating FTP user $ftp_user_name (home: $ftp_home_directory)"
        sudo adduser --disabled-password --home "$ftp_home_directory" --gecos "" "$ftp_user_name" >>"$LOGFILE" 2>&1
        echo "$ftp_user_name:$ftp_password" | sudo chpasswd >>"$LOGFILE" 2>&1
        echo "FTP User: $ftp_user_name, Password: $ftp_password, Home: $ftp_home_directory" >> "$CREDENTIALS_FILE"
      fi

      mkdir -p "$ftp_home_directory"
      chown "$site_user:$site_user" "$ftp_home_directory"
      sudo usermod -aG "$site_user" "$ftp_user_name" >>"$LOGFILE" 2>&1 || true
      sudo usermod -aG ftp-user "$ftp_user_name" >>"$LOGFILE" 2>&1 || true

      # Insert into local CP DB if missing
      exists_cnt="$(sqlite3 "$local_db_path" "SELECT COUNT(1) FROM ftp_user WHERE site_id = $local_site_id AND user_name = '$ftp_user_name';")"
      if [[ "$exists_cnt" == "0" ]]; then
        current_time="$(date '+%Y-%m-%d %H:%M:%S')"
        esc_user="$(printf "%s" "$ftp_user_name" | sed "s/'/''/g")"
        esc_home="$(printf "%s" "$ftp_home_directory" | sed "s/'/''/g")"
        sqlite3 "$local_db_path" "INSERT INTO ftp_user (site_id, created_at, updated_at, user_name, home_directory)
          VALUES ($local_site_id, '$current_time', '$current_time', '$esc_user', '$esc_home');" >>"$LOGFILE" 2>&1
        log "Inserted FTP user $ftp_user_name into local DB"
      else
        log "FTP user $ftp_user_name already present in local DB"
      fi
    done <<< "$ftp_users"

    # Restart ProFTPD if present
    if systemctl list-unit-files | grep -q '^proftpd\.service'; then
      log "Restarting ProFTPD"
      sudo systemctl restart proftpd >>"$LOGFILE" 2>&1 || log "WARN: ProFTPD restart failed"
    fi
  else
    log "No FTP users for $domain_name"
  fi

  # Cron jobs (rewrite file idempotently) — must include USER column
  cron_jobs="$(sqlite3 "$local_copy_path" "
    SELECT c.minute, c.hour, c.day, c.month, c.weekday, c.command
    FROM cron_job c
    WHERE c.site_id = $site_id;
  ")" || true

  if [[ -n "${cron_jobs// }" ]]; then
    cron_file="/etc/cron.d/$site_user"
    : > "$cron_file"
    while IFS="|" read -r minute hour day month weekday command; do
      [[ -z "${command// }" ]] && continue
      echo "$minute $hour $day $month $weekday $site_user $command" >> "$cron_file"
      # Mirror into local CP DB if missing
      current_time="$(date '+%Y-%m-%d %H:%M:%S')"
      esc_minute="$(printf "%s" "$minute" | sed "s/'/''/g")"
      esc_hour="$(printf "%s" "$hour" | sed "s/'/''/g")"
      esc_day="$(printf "%s" "$day" | sed "s/'/''/g")"
      esc_month="$(printf "%s" "$month" | sed "s/'/''/g")"
      esc_weekday="$(printf "%s" "$weekday" | sed "s/'/''/g")"
      esc_command="$(printf "%s" "$command" | sed "s/'/''/g")"
      exists_cron="$(sqlite3 "$local_db_path" "
        SELECT COUNT(1) FROM cron_job
        WHERE site_id=$local_site_id AND minute='$esc_minute' AND hour='$esc_hour' AND day='$esc_day'
          AND month='$esc_month' AND weekday='$esc_weekday' AND command='$esc_command';
      ")"
      if [[ "$exists_cron" == "0" ]]; then
        sqlite3 "$local_db_path" "INSERT INTO cron_job (site_id, created_at, updated_at, minute, hour, day, month, weekday, command)
          VALUES ($local_site_id, '$current_time', '$current_time', '$esc_minute', '$esc_hour', '$esc_day', '$esc_month', '$esc_weekday', '$esc_command');" >>"$LOGFILE" 2>&1
      fi
    done <<< "$cron_jobs"
    chmod 644 "$cron_file"
    log "Cron jobs written to $cron_file"
  else
    log "No cron jobs for $domain_name"
  fi

  log "--------------------------------------"
done <<< "$php_sites"

# --------------------------------------------------------------------
# Step 4: PHP sites with MySQL DBs (for DB operations)
# --------------------------------------------------------------------
log "Enumerating PHP sites with MySQL databases..."
php_sites_mysql="$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, d.name AS db_name, du.user_name AS db_user
FROM site s
JOIN database d ON s.id = d.site_id
JOIN database_user du ON d.id = du.database_id
WHERE s.type = 'php';
")"

if [[ -z "${php_sites_mysql// }" ]]; then
  log "No PHP+MySQL sites found. Done."
  exit 0
fi

log "Fetched PHP+MySQL sites:"
log "$php_sites_mysql"

# --------------------------------------------------------------------
# Step 5: Parallel export+copy (throttled)
# --------------------------------------------------------------------
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
    sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -n "$SSH_USER@$SSH_HOST" \
      "mkdir -p '$remote_backup_dir' && clpctl db:export --databaseName='$db_name' --file='$remote_sql_file'"
    rc1=$?
    if [ $rc1 -ne 0 ]; then
      echo "[${domain_name}] EXPORT FAILED (rc=$rc1)"
      echo "FAIL export" > "$status_file"
      exit 1
    fi
    echo "[${domain_name}] Export complete. Copying..."

    # Copy gz dump to local
    sshpass -p "$SSH_PASS" scp "${SCP_OPTS[@]}" < /dev/null \
      "$SSH_USER@$SSH_HOST:$remote_sql_file" "/tmp/${db_name}.sql.gz"
    rc2=$?
    if [ $rc2 -ne 0 ]; then
      echo "[${domain_name}] COPY FAILED (rc=$rc2)"
      echo "FAIL copy" > "$status_file"
      exit 1
    fi

    # Verify gzip integrity
    if ! gzip -t "/tmp/${db_name}.sql.gz" 2>/dev/null; then
      echo "[${domain_name}] COPY CORRUPT (gzip -t failed)"
      echo "FAIL gzip" > "$status_file"
      exit 1
    fi

    echo "[${domain_name}] Export+Copy SUCCESS"
    echo "OK" > "$status_file"
  } | tee -a "$LOGFILE"
}
export -f run_export_and_copy

# Throttle helper (Bash 4.4+ wait -n support detection)
have_wait_n=0
if bash -lc 'wait -n 2>/dev/null' 2>/dev/null; then have_wait_n=1; fi

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

log "Starting parallel export+copy jobs (max $MAX_JOBS)..."
while IFS="|" read -r _ domain_name site_user db_name _; do
  throttle
  run_export_and_copy "$domain_name" "$site_user" "$db_name" &
done <<< "$php_sites_mysql"

# Drain remaining jobs
if [ "$have_wait_n" -eq 1 ]; then
  while [ -n "$(jobs -pr)" ]; do
    wait -n || true
  done
else
  wait || true
fi

# Status check
fail_count=0
while IFS="|" read -r _ _ _ db_name _; do
  status_file="$STATUS_DIR/${db_name}.status"
  if [ ! -f "$status_file" ] || ! grep -q "^OK$" "$status_file"; then
    log "Export/copy failed for DB: $db_name — will SKIP import."
    fail_count=$((fail_count+1))
  fi
done <<< "$php_sites_mysql"

if [ $fail_count -gt 0 ]; then
  log "$fail_count database(s) failed in export/copy. See $STATUS_DIR and $LOGFILE."
fi

# --------------------------------------------------------------------
# Step 6: Create DBs and import dumps (SEQUENTIAL) + Laravel .env update
# --------------------------------------------------------------------
log "Creating databases and importing dumps..."
while IFS="|" read -r _ domain_name site_user db_name db_user; do
  status_file="$STATUS_DIR/${db_name}.status"
  if [ ! -f "$status_file" ] || ! grep -q "^OK$" "$status_file"; then
    log "Skipping import for $db_name due to failed export/copy."
    log "--------------------------------------"
    continue
  fi

  log "Setting up DB for site: $domain_name (DB: $db_name, User: $db_user)"

  # Random password for DB user
  db_password="$(openssl rand -base64 12)"

  # Idempotency: if DB already exists, skip creation (CloudPanel DB list is inside its own DB; simplest is to try and rely on clpctl error)
  log "Creating database $db_name for $domain_name..."
  if clpctl db:add \
      --domainName="$domain_name" \
      --databaseName="$db_name" \
      --databaseUserName="$db_user" \
      --databaseUserPassword="$db_password" >>"$LOGFILE" 2>&1; then
    log "DB $db_name created."
    {
      echo "Database credentials for $domain_name:"
      echo "DB Name: $db_name, DB User: $db_user, DB Password: $db_password"
    } >> "$CREDENTIALS_FILE"
  else
    log "WARN: DB add failed (maybe exists). Continuing to import with generated password logged."
    {
      echo "Database (possibly existing) for $domain_name:"
      echo "DB Name: $db_name, DB User: $db_user, DB Password (new attempt): $db_password"
    } >> "$CREDENTIALS_FILE"
  fi

  # Import dump
  local_sql_file="/tmp/${db_name}.sql.gz"
  if [ -f "$local_sql_file" ]; then
    log "Importing dump for $db_name..."
    if clpctl db:import --databaseName="$db_name" --file="$local_sql_file" >>"$LOGFILE" 2>&1; then
      log "Import OK for $db_name."
    else
      log "Import FAILED for $db_name."
    fi
  else
    log "Dump file not found: $local_sql_file. Skipping import for $db_name."
  fi

  # Optional: Update Laravel .env if present
  site_root="/home/$site_user/htdocs/$domain_name"
  if [ -f "$site_root/.env" ]; then
    update_laravel_credentials "$site_root/.env" "$db_name" "$db_user" "$db_password" "$domain_name"
  fi

  log "Finished DB setup for site: $domain_name"
  log "--------------------------------------"
done <<< "$php_sites_mysql"

# --------------------------------------------------------------------
# Done
# --------------------------------------------------------------------
log "All done. Migration completed at $(date)"
log "See credentials in $CREDENTIALS_FILE (permissions 600)."
