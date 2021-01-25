#!/bin/bash
#
# vim: nu et si sw=4 ts=4 sts=4

set -euo pipefail

# ensuring secure umask and restricting PATH
umask 0077
PATH="/bin:/usr/bin:/usr/local/bin"

# configuration variables
NAME=$(realpath $0)
SELF=$(basename $NAME)
TOOLS="mysqldump mysqlimport aws curl mail mydumper myloader"
LOCK_FILE="/var/run/$SELF.lock"

BACKUP_TS=$(date -Is)
TMP_DIR=$(mktemp -d)
THR=$(grep -c processor /proc/cpuinfo)

MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}" # default on rhel
MYSQL_BACKUP_DIR="${MYSQL_BACKUP_DIR:-/var/lib/mysql-files}" # default dir with secure-file-priv
PART_ROWS="200000"

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MAIL_ADDR="${MAIL_ADDR:-}"
S3_BUCKET="${S3_BUCKET:-s3://database-backup}"

# Error codes for abnormal exit.
E_SYNTAX=1
E_BACKUP=2
E_USAGE=70
E_USER=71
E_BACKUP_DIR=72
E_CMD_NOT_AVAIL=73
E_MULTI_INSTANCE=74
E_LOW_SPACE=75
E_S3_ACCESS=76

# --- code
usage() {
    cat <<EOF
$SELF -- mysql backup/restore script.

Usage: $SELF {-b|-r <id>} [optional parameters]

Parameters:

-- modes:
    -b          create a database backup
    -r <id>     restore a database backup with ID <id>
-- aws:
    -a <file>   AWS credentials (if not configured)
    -3 <s3 url> AWS S3 bucket URL. Empty URL disables upload.
-- backup/restore:
    -c <file>   my.cnf-style file with credentials specified
                in [client] section. 
    -r <num>    <num> rows per data chunkfile.
    -t <dir>    backup directory where dump files are stored      
-- notifications:
    -m <addr>   email address to send notifications to.
    -w <webhook> 
                slack webhook URL.

EOF
}

alert() {
    local MSG=$(echo $1 | sed 's#["\]#_#g') # quick and dirty sanitizing
    
    if [ ! -z "$SLACK_WEBHOOK" ]; then  
        curl -s -X POST \
            --data-urlencode 'payload={"text":"'"$MSG"'","icon_emoji":":ghost:"}' \
            $SLACK_WEBHOOK >/dev/null || :
    fi

    # we can send mail with curl too, but it's more cumbersome
    if [ ! -z "$MAIL_ADDR" ]; then
        echo "$MSG" | mail -s "`hostname`: $SELF notification" $MAIL_ADDR || :
    fi
}

log() { echo "$(date -Is): $*"; }
err() { echo "$(date -Is): ERR: $*" >&2; alert ":exclamation: $MODE $BACKUP_TS: ERROR: $*"; }

check_config() {
    log "Checking backup/restore configuration ..."
    [[ -d "$MYSQL_BACKUP_DIR" && -w "$MYSQL_BACKUP_DIR" ]] || {
        err "Backup directory does not exist or isn't writable: $MYSQL_BACKUP_DIR"
        exit $E_BACKUP_DIR
    }
    for cmd in $TOOLS; do
        hash $cmd 2>/dev/null || {
            err "$cmd: not available"
            exit $E_CMD_NOT_AVAIL
        }
    done

    if [ ! -z "$S3_BUCKET" ]; then
        aws s3 ls "$S3_BUCKET" >/dev/null || {
            err "Unable to access S3 bucket"
            exit $E_S3_ACCESS
        }
    fi
    # more checks here if/when necessary
}

check_node() {
    log "Checking the node vitals ..."

    local DB_SIZE=$(du -s ${MYSQL_DATA_DIR}/ | awk '{print $1}')
    local FREE_SPACE=$(df -P ${MYSQL_BACKUP_DIR}/ | awk 'NR==2{print $4}')

    # ensure we have enough free space for the backup;
    # rule of thumb: tab backup takes at least twice less than the DB
    log "db_size=${DB_SIZE}k free_space=${FREE_SPACE}k"
    [[ $FREE_SPACE -gt $((DB_SIZE/2)) ]] || {
        err "Not enough space for the backup: $((FREE_SPACE/1024))M free < ($((DB_SIZE/1024))M DB /2)"
        exit $E_LOW_SPACE
    }

    # more checks here if necessary: cpu / swap / load ave / disk space / net connectivity
}

cleanup() {
    trap '' EXIT INT HUP
    log "Running cleanup..."
   
    # kill all child processes
    kill $(ps -s $$ -o pid=) 2>/dev/null || :
    # remove temp directory
    [[ ! -z "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || :

    log "Cleanup done"
}

backup_progress() {
    # this background function provides process indication
    
    local ppid=$1
    local SLEEP=2
    local prev=""

    trap return HUP
    sleep $SLEEP
    # while parent process exists
    while [ $ppid -eq $(ps -fp $BASHPID -o ppid=) ]; do
        # return if backup is completed:
        [ ! -d "$MYSQL_BACKUP_DIR/${BACKUP_TS}-schema" -a -d "$MYSQL_BACKUP_DIR/$BACKUP_TS" ] || return 

        local cur=$(ls -lt --block-size=M $MYSQL_BACKUP_DIR/$BACKUP_TS 2>/dev/null | \
              awk '/total/{t=$2}END{print "files:",NR-1,"size:",t}' || :)
        [ "$cur" == "$prev" ] && return
        log "[progress] $cur"
        prev=$cur
        sleep $SLEEP
    done
}

s3upload() {
    [ -z "$S3_BUCKET" ] && return # skipping upload if bucket is set to empty string

    log "[s3upload] Uploading $BACKUP_TS backup to $S3_BUCKET ..."
    log "[s3upload] Schema:"
    tar cf - -C / $(echo "$MYSQL_BACKUP_DIR/${BACKUP_TS}-schema" | sed 's#^/##') | pv | \
       aws s3 cp - "$S3_BUCKET/${BACKUP_TS}-schema.tar" && {
           rm -rf "$MYSQL_BACKUP_DIR/${BACKUP_TS}-schema"; 
       } || {
           err "[s3upload] Failed to upload schema backup to $S3_BUCKET; leaving it on disk."
       }

    log "[s3upload] Full:"
    tar cf - -C / $(echo "$MYSQL_BACKUP_DIR/${BACKUP_TS}" | sed 's#^/##') | pv | \
       aws s3 cp - "$S3_BUCKET/${BACKUP_TS}.tar" && {
           rm -rf "$MYSQL_BACKUP_DIR/${BACKUP_TS}"; 
       } || {
           err "[s3upload] Failed to upload full backup to $S3_BUCKET; leaving it on disk."
       }
}

backup() {
    log "Backing up databases ..."
    backup_progress "$BASHPID" &

    mydumper $MYSQL_CREDS \
        -o $MYSQL_BACKUP_DIR/$BACKUP_TS \
        -r $PART_ROWS \
        -t $THR \
        --compress \
        --regex '^(?!(sys\.|information_schema\.|performance_schema\.))' \
        --trx-consistency-only \
        --triggers --events --routines \
        --compress \
        -L "$TMP_DIR/backup.log" || { 
                err "Backup failed. Full log is available at: $TMP_DIR/backup.log"
                err "Last 10 lines of the log:"
                tail -10 "$TMP_DIR/backup.log" >&2
                exit $E_BACKUP
        }
    kill -HUP %1
    log "Backup completed."
    log "Creating schema archive ..."
    mkdir $MYSQL_BACKUP_DIR/${BACKUP_TS}-schema || { 
        err "Failed to create schema backup directory"; 
        exit $E_BACKUP_DIR
    }
    cp $MYSQL_BACKUP_DIR/$BACKUP_TS/*schema* $MYSQL_BACKUP_DIR/${BACKUP_TS}-schema

    s3upload
}

restore() {
    log "Restoring from backup..."

    DIRS=""
    if [ -z "$DATABASES" ]; then
        DIRS=$(ls -1d $MYSQL_BACKUP_DIR/*)
    else
        for DB in $DATABASES; do
            DIRS="$DIRS $MYSQL_BACKUP_DIR/$DB"
        done
    fi

    for backup_dir in $DIRS; do
        DB=$(basename $backup_dir)
        log "Restoring database $DB..."

        mysql -e 'drop database if exists '"$DB"'; create database '"$DB"';set global FOREIGN_KEY_CHECKS=0;'
        
        # restore schema
        (echo "SET FOREIGN_KEY_CHECKS=0;"; cat $backup_dir/schema.sql) | mysql $MYSQL_CREDS $DB

        # load data
        mysqlimport $MYSQL_CREDS --use-threads=4 $DB $backup_dir/*.txt
    done 
}

list() {
    log "Retrieving available backups ..."
    local SCHEMAS=$(aws s3 ls "$S3_BUCKET" | grep 'schema.tar' || : )

    [ -z "$SCHEMAS" ] && { log "No backups available"; return; }
    log "Available backup timestamps:"
    echo "$SCHEMAS" | awk '{print ">", $4}' | \
        sed 's#-schema.tar##' | while read line; do
            log $line
        done
    log "Restore with: $SELF -r <backup timestamp>"
}

# --- main

# ensure only single instance of script is running
exec 9<"$NAME"
flock -n 9 || {
    err "$SELF is already running. Only single instance running is allowed"
    exit $E_MULTI_INSTANCE
}

MODE=""
MYSQL_CREDS=""
# parse command line args
while getopts ":brla:3:c:r:t:w:" opt; do
    case $opt in
        b) MODE="backup";;
        r) MODE="restore"; BACKUP_TS="$OPTARG";;
        l) MODE="list";;
        a) [ -f "$OPTARG" ] && source "$OPTARG";;
        3) S3_BUCKET="$OPTARG";;
        c) MYSQL_CREDS="--defaults-file=$OPTARG";;
        r) PART_ROWS=$OPTARG;;
        t) MYSQL_BACKUP_DIR="$OPTARG";;
        w) SLACK_WEBHOOK="$OPTARG";;
        ?) usage; exit $E_SYNTAX;; 
    esac
done

[ -z "$MODE" ] && { usage; exit $E_SYNTAX; }

# install a cleanup traps
trap cleanup INT HUP EXIT

# sanity checks
check_config
check_node

case $MODE in
    backup) backup;;
    restore) restore;;
    list) list; exit 0;; # avoid notifications
    *) usage; exit $E_SYNTAX;;
esac

alert "$MODE $BACKUP_TS completed."
