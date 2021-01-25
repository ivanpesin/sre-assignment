# SRE test assignment

> For the assignment description, please refer to `SRE_practical_task.pdf`.

## Operational documentation

### Summary

`backup.sh` is a backup/restore script for large MySQL instances with following characteristics:

- process progress is logged to `stdout`
- errors are handles and logged to `stderr`
- critical errors are reported via following notification channels: _slack_ and _email_
- backup and restore procedures are parallelized to improve performance
- data and schema are backed up separately
- the resulting backup is uploaded to S3 bucket; data is compressed and upload is parallelized to reduce time requirements
- the restore downloads backups from S3 or uses on-disk copy; download is parallelized and runs in background to reduce time requirements
- the restore process does staged restoration with checks:
  - imports the schema first and then checks tables for corruption
  - imports the data and then checks tables for corruption
  - finally it runs `SELECT COUNT(*)` statements on three random tables and compares record counts with backup

### Usage

```
backup.sh -- mysql backup/restore script.

USAGE: backup.sh {-b|-r <id>|-l} [options]

OPTIONS:

-- modes:
    -b          create a database backup
    -r <id>     restore a database backup with ID <id>
    -l          list backups available for restore
-- aws:
    -a <file>   AWS credentials (if not configured)
    -3 <s3 url> AWS S3 bucket URL. Empty URL disables upload
-- backup/restore:
    -c <file>   my.cnf-style file with credentials specified
                in [client] section (if not configured in my.cnf) 
    -r <num>    <num> rows per data chunkfile
    -t <dir>    backup directory where dump files are stored      
-- notifications:
    -m <addr>   email address to send notifications to
    -w <webhook> 
                slack webhook URL

Instead of options you can use ENVIRONMENT VARIABLES:

  S3_BUCKET         AWS S3 bucket URL
  SLACK_WEBHOOK     slack webhook URL
  MAIL_ADDR         email address to send notifications to
  MYSQL_BACKUP_DIR  backup directory where dump files are stored
```

> NOTE: the user running the script _MUST_ have read access to MySQL data directory; this is for the script to make estimation of free space required for the backup.

### Operation screencasts

>NOTE: In the below screencasts, MySQL credentials are specified in `[client]` section of `~/.my.cnf`, **aws-cli** is configured, and slack/email notification destinations are specified via _environment variables_.

#### Creating a backup

![backup](https://github.com/ivanpesin/sre-assignment/raw/main/backup.gif)

#### Listing available S3 backups

![backup](https://github.com/ivanpesin/sre-assignment/raw/main/list-backups.png)
