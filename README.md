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

![list-backups](https://github.com/ivanpesin/sre-assignment/raw/main/list-backups.png)

#### Restoring backup

![restore](https://github.com/ivanpesin/sre-assignment/raw/main/restore.gif)
> NOTE: this screencast uses local backup to make the recording shorter.

## Assignment assumptions and considerations

### Assumptions

1. **MySQL version 8.0**: the task does not specify the MySQL version; I'm assuming 8.0. The scripts and overall approach is applicable to 5.6/5.7, but I only tested on MySQL 8.0. I am also assuming that only InnoDB tables are used.

2. **Single node installation**: the task does not specify whether the setup is clustered, replicated, or single node. Given the limited scope for this assignment I'm assuming it's a single node installation. 

3. **CentOS8 linux environment**: the task does not specify Linux flavor; I'm assuming CentOS8 as this is a very common server distribution for production systems. This shouldn't affect the scripts and approach, but there might be differences in paths to system utilities used in the backup/restore scripts. Due to limited scope of this assignment, I'm ignoring SELinux configuration aspects.

4. MySQL database is located on a filesystem/block device/volume that **does *NOT* support snapshots**, i.e. not on LVM/ZFS/EBS/etc. The reasons for this assumption: 
   - LVM/ZFS negatively impact MySQL performance; therefore many installations avoid such setup.
   - if the database is located on a volume which supports snapshots then doing a raw backup off the snapshot might be the most efficient way to backup and restore; such approach, however, seems to be in disagreement with the criteria listed in the assignment (backup data and scheme separately).

### Considerations

#### Backup/restore

Let's consider available backup/restore options:

- **hot vs cold backups**: there is nothing specified in the assignment, and if cold backups were acceptable, we'd just stop or flush and lock the DB and copy files. Then we can start the main instance back up, fire up another `mysqld` instance off backed up files and generate separate schema and data backups as required in the assignment. The script is not required to restore off SQL files specifically, so we can just restore off raw files achieving speed requirement. Smells like trickery, however, so I'm assuming we have to keep the main instance online during the backup.
- **incremental backups**: this would reduce the amortized time of backing up, but usually complicates the recovery, which means slows it down. This directly contradicts the requirements (restore speed more important than backup speed), so crossing this out.
- **raw vs logical backups**: For 150G dataset, the only viable backup/restore option is raw backups. One can further enhance such setup with exporting logical dumps off a raw backup, include replicas, and so on. The assignment, however, **specifically** tells to produce separate logical backups for schema and data. Given the limited scope of the assignment and the fact that raw hot backups are done best with snapshotting feature which I have already assumed not available, I decided to limit myself to only one type of backup, the one which is explicitly requested: **logical**. 

Sticking with logical backup rules out the most popular backup suites for large MySQL instances: _Percona XtraBackup_ and _MySQL Enterprise Backup_. One of the reasons these tools are popular is that they are fast. The trouble with logical backups _and_ restores is that they are _slow_. The standard tool `mysqldump` does backing up and restoring in a single thread, so even if we have _fast_ storage, CPU, and RAM, it would still max out on a single core. However, the biggest problem is not the dumping performance, but rather the restore performance. It's even worse, because MySQL needs to rebuild the whole database off SQL statements. The assignment specifically emphasizes backup and restore _speed_, so we need to find a way to parallelize, or significantly improve single-threaded speed, or both!

Standard logical backup/restore options are: `mysqldump`,`mysqlpump`, and quite recently `mysqlsh` with `dumpInstance()` and `loadDump()`. `mysqlpump` does backup in parallel, but the restore is still single-threaded. This again contradicts the requirements, so `mysqlpump` is out. `mysqlsh` actually looks  exactly like what the assignment looks for: it can parallelize both dumping and restoring, it compresses files, and produces schema and data files separately. Unfortunately, it is a fairly new utility and it does not support MySQL 5.6. Let's disqualify it, as it's not unreasonable to assume we don't want to use a new tool for such a critical task as backup handling. 

