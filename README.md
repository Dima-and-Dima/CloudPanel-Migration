#CloudPanel PHP Site Migration Script

This Bash script automates the migration of PHP sites from one CloudPanel server to another. It handles the following steps:

    Copying the remote CloudPanel SQLite database.
    Retrieving and processing PHP site data (domains, users, PHP versions).
    Creating PHP sites on the local server using clpctl.
    Copying vhost configurations, SSL certificates, FTP users, and cron jobs.
    Dumping, copying, and restoring MySQL databases for each site.
    Syncing the site content from the remote server to the local server using rsync.

Prerequisites

Before using this script, ensure the following tools are installed on both the local and remote servers:

    sshpass
    sqlite3
    rsync
    openssl

These will be automatically installed by the script if missing.
Script Overview

The script performs the following steps:

    Database Copy: Connect to the remote server and copy the CloudPanel SQLite database for processing.
    Site Creation: Loop through all PHP sites, create each site locally using clpctl, and configure vhost settings, SSL certificates, FTP users, and cron jobs.
    Database Operations: Dump the MySQL databases from the remote server, transfer them, and import them into the local MySQL instance.
    Site Content Sync: Use rsync to copy the site files (HTML, PHP, etc.) from the remote server to the local server, maintaining the directory structure.

Script Usage

    Clone this repository and edit the script to add the following:

    Remote server SSH details:        
    
    ssh_user="<SSH_USER>"
    ssh_host="<SSH_HOST>"
    ssh_pass="<SSH_PASSWORD>"

Paths to the SQLite database:



    remote_db_path="/home/clp/htdocs/app/data/db.sq3"
    local_db_path="/home/clp/htdocs/app/data/db.sq3"

Run the script:



    ./migration_script.sh

    The script logs output to /tmp/mysql_dump_debug.log and stores credentials in /tmp/credentials.log.

Example Workflow

    Install Required Tools: If tools like sshpass or sqlite3 are not installed, the script will automatically install them.
    Copy Database: The remote SQLite database is copied locally for reading site data.
    Create PHP Sites: The script iterates over each site, creates it locally using clpctl, and updates the local CloudPanel SQLite database with vhost settings, application type, and caching.
    Rsync Site Content: After creating the sites and MySQL databases, the script uses rsync to copy site content from the remote to the local server.
    Logging: Throughout the process, the script logs successes and errors, making it easy to identify any issues.

Logging and Debugging

All output and errors are logged to /tmp/mysql_dump_debug.log, making it easy to troubleshoot any problems that arise during the migration.
Customization

You can modify the script to adjust:

    Default values for missing PHP versions, user credentials, and passwords.
    SSH connection details for connecting to the remote server.
    Backup and restore paths for database dumps.

License

This project is licensed under the MIT License. See the LICENSE file for details.
