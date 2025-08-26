# CloudPanel PHP Site Migration

Automate migrating PHP sites between **CloudPanel** servers — including site setup, configuration, content, FTP users, cron jobs, MySQL databases, and optional Laravel `.env` updates.

---

## Table of Contents

1. [Overview](#overview)  
2. [Features](#features)  
3. [Prerequisites](#prerequisites)  
4. [Installation](#installation)  
5. [Configuration](#configuration)  
6. [Usage](#usage)  
7. [Workflow](#workflow)  
8. [Safety & Idempotency](#safety--idempotency)  
9. [Post-Migration Steps](#post-migration-steps)  
10. [Troubleshooting](#troubleshooting)  
11. [Logs](#logs)  
12. [License](#license)  

---

## Overview

This Bash script streamlines migrating multiple PHP sites (and their MySQL databases) from one CloudPanel server to another.  
It uses the CloudPanel CLI (`clpctl`) with `rsync`, `sshpass`, and `sqlite3` to handle every step end-to-end with minimal downtime.

---

## Features

- **Site setup**: Auto-creates PHP sites with fallback defaults  
- **Config sync**: Copies Nginx configs and SSL certificates  
- **Content sync**: Rsyncs site files with ownership/permissions  
- **FTP users**: Re-creates FTP users with random secure passwords  
- **Cron jobs**: Migrates cron jobs, fixes `/etc/cron.d` format (includes user column)  
- **MySQL**:  
  - Parallel **export + copy** (throttled via `MAX_JOBS`)  
  - Gzip integrity check before import  
  - Sequential **create + import** into new CloudPanel  
- **Laravel**: Safely updates `.env` DB credentials with escaping  
- **Idempotent**: Skips already existing sites, users, cron jobs on re-run  
- **Secure**: Credentials logged with `chmod 600`, `umask 077`  

---

## Prerequisites

- **Destination server**: Ubuntu 18.04+ with CloudPanel installed  
- **Source server**: SSH access with `clpctl` permissions  
- **Installed automatically if missing**:  
  - `sshpass`, `sqlite3`, `rsync`, `openssl`, `gzip`

---

## Installation

Clone the repository on your **destination server**:

```bash
git clone https://github.com/rick001/CloudPanel-Migration.git
cd CloudPanel-Migration
chmod +x migration.sh
```

---

## Configuration

You can either **export env vars** before running or edit the top of `migration.sh`:

```bash
export SSH_USER=myuser
export SSH_HOST=source.server.com
export SSH_PASS='mypassword'
export SSH_PORT=22
```

Optional knobs:

- `MAX_JOBS=3` → control concurrency of parallel export+copy  
- Paths:  
  - `remote_db_path` = `/home/clp/htdocs/app/data/db.sq3`  
  - `local_db_path` = `/home/clp/htdocs/app/data/db.sq3`

---

## Usage

Run the migration:

```bash
./migration.sh
```

The script will:

1. Copy the remote CloudPanel SQLite DB  
2. Create sites (with PHP version, vhost, users)  
3. Copy Nginx conf + SSL certs  
4. Rsync site content  
5. Re-create FTP users + cron jobs  
6. Export+copy MySQL DBs (parallel)  
7. Create DBs + import dumps (sequential)  
8. Update Laravel `.env` if found  

---

## Workflow

- **Sequential**  
  - Site creation, config sync, FTP, cron, DB creation/import  
- **Parallel (throttled)**  
  - MySQL DB export+copy (`MAX_JOBS` controls concurrency, default 3)  
- **Integrity checks**  
  - `gzip -t` validates `.sql.gz` dumps before import  

---

## Safety & Idempotency

- Re-running the script:  
  - Skips existing sites in local CloudPanel DB  
  - Skips existing FTP users and cron jobs  
  - Skips failed DB exports (status written under `/tmp/migrate_status`)  
- Credentials: stored at `/tmp/credentials.log` (permissions `600`)  
- Logs: detailed step-by-step output in `/tmp/clp_migration_debug.log`

---

## Post-Migration Steps

- Reload/restart Nginx + PHP-FPM if required:
  ```bash
  sudo systemctl reload nginx
  ```
- Test migrated sites before DNS switch (e.g., use `/etc/hosts`)  
- For Laravel apps:  
  ```bash
  php artisan config:cache
  ```
- Once verified, update DNS to point to the new server

---

## Troubleshooting

- **SSH issues**: ensure firewall allows port, check `SSH_USER` has rights  
- **DB export hangs**: lower `MAX_JOBS` to `1` or `2`  
- **Corrupt dumps**: check `gzip -t` log entries  
- **Rerun needed**: clear `/tmp/migrate_status/` and `/tmp/credentials.log`

---

## Logs

- **Debug log**: `/tmp/clp_migration_debug.log`  
- **Credentials**: `/tmp/credentials.log`  
- **Per-DB status**: `/tmp/migrate_status/<db_name>.status`

---

## License

MIT License — see [LICENSE](LICENSE).

---

## Acknowledgements

Based on [CloudPanel official migration best practices](https://www.cloudpanel.io/docs/) and extended with automation, idempotency, and Laravel support.
