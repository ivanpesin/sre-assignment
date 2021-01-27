# SRE test assignment

> For the assignment description, please refer to `SRE_practical_task.pdf`.

- [SRE test assignment](#sre-test-assignment)
  - [Operational documentation](#operational-documentation)
    - [Summary](#summary)
    - [Usage](#usage)
    - [Operation screencasts](#operation-screencasts)
      - [Creating a backup](#creating-a-backup)
      - [Listing available S3 backups](#listing-available-s3-backups)
      - [Restoring backup](#restoring-backup)
  - [Assignment assumptions and considerations](#assignment-assumptions-and-considerations)
    - [Assumptions](#assumptions)
    - [Considerations](#considerations)
      - [Backup/restore](#backuprestore)
      - [Other considerations](#other-considerations)
  - [Further thoughts](#further-thoughts)

## Operational documentation

### Summary

`backup.sh` is a backup/restore script for large MySQL instances with following characteristics:

- process progress is logged to `stdout`
- errors are handled and logged to `stderr`
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
   - LVM/ZFS negatively impact MySQL performance (see for example [percona blog on ZFS](https://www.percona.com/blog/2018/02/16/why-zfs-affects-mysql-performance/); therefore many installations avoid such setup.
   - if the database is located on a volume which supports snapshots then doing a raw backup off the snapshot might be the most efficient way to backup and restore; such approach, however, seems to be in disagreement with the criteria listed in the assignment (backup data and scheme separately).

### Considerations

#### Backup/restore

Let's consider available backup/restore options:

- **hot vs cold backups**: there is nothing specified in the assignment, and if cold backups were acceptable, we'd just stop or flush and lock the DB and copy files. Then we can start the main instance back up, fire up another `mysqld` instance off backed up files and generate separate schema and data backups as required in the assignment. The script is not required to restore off SQL files specifically, so we can just restore off raw files achieving speed requirement. Smells like trickery, however, so I'm assuming we have to keep the main instance online during the backup.
- **incremental backups**: this would reduce the amortized time of backing up, but usually complicates the recovery, which means slows it down. This directly contradicts the requirements (restore speed more important than backup speed), so crossing this out.
- **raw vs logical backups**: For 150G dataset, the only viable backup/restore option is raw backups. One can further enhance such setup with exporting logical dumps off a raw backup, include replicas, and so on. The assignment, however, **specifically** tells to produce separate logical backups for schema and data. Given the limited scope of the assignment and the fact that raw hot backups are done best with snapshotting feature which I have already assumed not available, I decided to limit myself to only one type of backup, the one which is explicitly requested: **logical**. 

Sticking with logical backup rules out the most popular backup suites for large MySQL instances: _Percona XtraBackup_ and _MySQL Enterprise Backup_. One of the reasons these tools are popular is that they are fast. The trouble with logical backups _and_ restores is that they are _slow_. The standard tool `mysqldump` does backing up and restoring in a single thread, so even if we have _fast_ storage, CPU, and RAM, it would still max out on a single core. However, the biggest problem is not the dumping performance, but rather the restore performance. It's even worse, because MySQL needs to rebuild the whole database off SQL statements. The assignment specifically emphasizes backup and restore _speed_, so we need to find a way to parallelize, or significantly improve single-threaded speed, or both!

Standard logical backup/restore options are: `mysqldump`,`mysqlpump`, and quite recently `mysqlsh` with `dumpInstance()` and `loadDump()`. `mysqlpump` does backup in parallel, but the restore is still single-threaded. This again contradicts the requirements, so `mysqlpump` is out. `mysqlsh` actually looks  exactly like what the assignment looks for: it can parallelize both dumping and restoring, it compresses files, and produces schema and data files separately. Unfortunately, it is a fairly new utility and it does not support MySQL 5.6. Let's disqualify it, as it's not unreasonable to assume we don't want to use a new tool for such a critical task as backup handling. 

This leaves as with a venerable `mysqldump`, and a 3rd party `mydumper/myloader`. We can speed up `mysqldump` performance by using its TSV mode; this  also should improve the restore speed, as it's going to use `LOAD DATA` statements (`mysqlimport` wrapper). This approach, however, requires splitting data files and then carefully managing parallelism (read: more code and time to implement)to really achieve significant performance improvement. On the other hand, `mydumper/myloader` has long been around, proven in production environments, and provides parallelism boost right out of the box.

Here is some performance data for backup/restore methods considered:

![dump](https://mysqlserverteam.com/wp-content/uploads/2020/07/dump-1.png)

![restore](https://mysqlserverteam.com/wp-content/uploads/2020/07/load-1.png)

> source: [MySQL Server Blog](https://mysqlserverteam.com/mysql-shell-dump-load-part-2-benchmarks/)

As evidenced above, `mydumper` is way more performant than `mysqldump`/`mysqlpump`, trailing behind `mysqlsh`. [Percona test](https://www.percona.com/blog/2018/02/22/restore-mysql-logical-backup-maximum-speed/) also suggest that `mydumper` performance on backup/restore with default parameters is similar to highly optimized `mysqldump --tab/mysqlimport` approach.

Thus, for this assignment I am going to use `mydumper/myloader` as the backup tool.

#### Other considerations

`bash` seems perfectly suitable for this type of script, so I'll stick with it.

For notifications I usually use [Apprise](https://github.com/caronc/apprise/wiki/CLI_Usage) which can send notifications to most notification services, including Slack, email, etc. Being a 3rd-party tool (although available in semi-standard EPEL repo), I wouldn't assume its availability and will implement Slack and email notifications using standard tools. I am assuming that sendmail/postfix is properly configured on the database node and that Slack API is accessible either directly or via proxy.

I will use **S3** for backup storage, and will use tokens for authentication. Using S3 endpoint is possible without token authentication, but then it implies the DB node is on AWS. If the node were on AWS, then we'd have EBS for storage, and then we could've used EBS snapshotting for backup strategy, but we have ruled out this possibility earlier in the Assumptions. I also assume that security configuration/management such as access permissions, encryption, etc is out of scope for this assignment.

To account for speed requirement, the upload to S3 will be precompressed and parallelized (aws-cli version 2 parallelizes uploads and downloads for `cp` and `sync` commands. See [this AWS post](https://aws.amazon.com/blogs/apn/getting-the-most-out-of-the-amazon-s3-cli/): "if the files are over a certain size, the AWS CLI automatically breaks the files into smaller parts and uploads them in parallel".)

Restore tests are a complex subject and can be implemented in a multitude of ways. Here is the strategy I'll implement:

1. To ensure consistent restore process, we need to start with backups. As we only use transactional InnoDB tables, the backup procedure will use transactional consistency approach.
2. Import schema from the backup. Schemas are relatively small, so the import will be quick and will pick up most corruptions in the backup schema files.
3. Run `mysqlcheck` to check all database tables for the corruption after backup import.
4. Import the data. This stage will pick up most corruptions in the backup data files.
5. Re-run `mysqlcheck` to check all database tables for the corruption after backup import.
6. Pick 3 random tables from the backup and compare record counts in database and backup files.

There are other important checks that I have not implemented due to limited scope and time, but including here for reference: 
- table checksumming before/during the backup; this will allow checksum validation after backup restore
- database backup after restore and comparison to the source backup; they should be identical
- content checks which require knowledge of data in the database. For example, if a database table contains metadata about the files on disk storage, we can run the query to ensure that all records reference existing files, or that all files in storage have an entry in the database.

For script testing I'm going to use the following datasets: Sakila, Employee, and some large tables from Wiki dumps.

## Further thoughts

As I mentioned before, the first thing to improve with this backup approach is to move to raw backups as a primary technique. This will greatly improve both backup and restore speed. I'd use _Percona XtraBackup_ for this.

Then, adding the read-only replica would allow more flexibility in terms of how and where to backup: shift backup performance impact from the master to slave nodes, speed up recovery in certain situations by promoting slave instead of restore, etc.

The next step would be putting the database on a block device or filesystem that supports snapshotting. This would further improve backup capabilities in terms of performance and consistency.

All these steps permit fulfilling existing requirements of backing up schema/data separately and perform recovery testing while improving backup/recovery capabilities. For example, one strategy might be as follows:

* Backup:
  - perform hot raw backup with _Percona XtraBackup_ 
  - start second _mysqld_ instance off the backup files
  - run healthchecks/consistency checks to ensure the copy is valid
  - perform `mysqldump` off second instance to backup data and schema separately
  - upload compressed backups (both raw and logical) and checksum file to cloud storage
  - keep N backups locally for faster recovery
- Restore testing:
  - download backups from cloud if not cached locally
  - verify downloaded files for corruption with checksums
  - restore schema, check tables for corruption
  - restore data, check tables for corruption
  - run data-aware checks (query table row counts, table checksums, data validation)
  - perform `mysqldump` off restored instance similar to how it was done during backup. Files produced should be exactly match logical backup files from which instance was restored
  - repeat testing for raw backup: restore, check tables for corruption, run data-aware checks, `mysqldump`
- Restore:
  - download raw backup from cloud if not cached locally
  - verify downloaded files for corruption with checksums
  - restore database


