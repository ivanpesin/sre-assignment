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
ID=$(date -Is)

MYSQL_UID=$(getent passwd mysql | cut -d: -f3)
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/var/lib/mysql}" # default on rhel
MYSQL_BACKUP_DIR="${MYSQL_BACKUP_DIR:-/var/lib/mysql-files}" # default dir with secure-file-priv

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MAIL_ADDR="${MAIL_ADDR:-}"
S3_BUCKET="${S3_BUCKET:-s3://database-backup}"

TOOLS="mysqldump mysqlimport aws curl mail mydumper myloader"
LOCK_FILE="/var/run/$SELF.lock"

TMP_DIR=$(mktemp -d)

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
    -3 <s3 url> AWS S3 bucket URL
-- backup/restore:
    -c <file>   my.cnf-style file with credentials specified
                in [mysql], [mysqldump], and [mysqlimport] sections. 
    -d <db1,db2,...>
                comma separated list of DBs to backup/restore; optional.
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
err() { echo "$(date -Is): ERR: $*" >&2; alert ":exclamation: $MODE $ID: ERROR: $*"; }

check_config() {
    log "Checking backup/restore configuration..."
    [[ "$UID" == "$MYSQL_UID" ]] || {
        err "Script is not running as mysql user, uid $UID != mysql uid $MYSQL_UID"
        exit $E_USER
    }
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

    if [ ! -z "$S3_BUCKET"]; then
        aws s3 ls "$S3_BUCKET" >/dev/null || {
            err "Unable to access S3 bucket"
            exit $E_S3_ACCESS
        }
    fi
    # more checks here if/when necessary
}

check_node() {
    log "Checking the node vitals..."

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
    local DB=$1
    local SLEEP=2
    local STATE="$TMP_DIR/backup_progress.$DB"

    rm -f "${STATE}*"

    until [ -f "${STATE}.done" -o ! -d "$MYSQL_BACKUP_DIR/$DB" ]; do
        sleep $SLEEP
        ls -l --block-size=M $MYSQL_BACKUP_DIR/$DB 2>/dev/null | \
            awk '!/^total/&&NF==9{print $9,"size:",$5}' > "${STATE}.new" || :
        if [ -f "$STATE" ]; then
            DIFF=$(diff -u "$STATE" "${STATE}.new" || :)
            if [ -z "$DIFF" ]; then
                touch "${STATE}.done"
            else
                log "[progress] $(echo "$DIFF" | grep '^+[^+]')"
            fi 
        fi
        cp -f ${STATE}.new ${STATE}
    done
}

s3upload() {
    local DB=$1
    [ -z "$S3_BUCKET" ] && return # skipping upload if bucket is set to empty string

    log "[s3upload] Uploading $DB data to $S3_BUCKET..."
    tar cjf - -C / $(echo "$MYSQL_BACKUP_DIR/$DB" | sed 's#^/##') | \
       aws s3 cp - "$S3_BUCKET/$DB-$ID.tbz2" && {
           log "[s3upload] Uploaded $DB to $S3_BUCKET"
           rm -rf "$MYSQL_BACKUP_DIR/$DB"; 
       } || {
           err "[s3upload] Failed to upload $DB backup to $S3_BUCKET; leaving backup on disk."
       }
}

backup() {
    
    if [ -z "$DATABASES" ]; then
        # get list of DBs to backup; creds from my.cnf or specified with -c
        DATABASES=$(mysql $MYSQL_CREDS -NBe 'show databases;' | \
          egrep -v 'sys|information_schema|performance_schema' || : )
    
        [ ! -z "$DATABASES" ] || {
            err "Unable to retrieve list of databases"
            exit $E_BACKUP
        }
    fi

    log "DBs to backup: $DATABASES"

    for DB in $DATABASES; do
    #    [ -z "$DB" ] && continue # could be stay empty line

        mkdir $MYSQL_BACKUP_DIR/$DB || {
            err "Failed to create $MYSQL_BACKUP_DIR/$DB"
            exit $E_BACKUP
        }

        log "Backing up $DB ..."
        backup_progress $DB &

        
        mysqldump $MYSQL_CREDS \
            --no-data \
            --max_allowed_packet=128M \
            --single-transaction \
            --result-file $MYSQL_BACKUP_DIR/$DB/schema.sql \
            $DB > "$TMP_DIR/$DB.log" 2>&1 || {
                err "Backup of $DB failed. Full log is available at: $TMP_DIR/$DB.log"
                err "Last 10 lines of the log:"
                err "$(tail -10 $TMP_DIR/$DB.log)"
                exit $E_BACKUP
            }

        mysqldump $MYSQL_CREDS \
            --no-create-info  \
            --max_allowed_packet=128M \
            --tab $MYSQL_BACKUP_DIR/$DB \
            --single-transaction \
            $DB > "$TMP_DIR/$DB.log" 2>&1 || {
                err "Backup of $DB failed. Full log is available at: $TMP_DIR/$DB.log"
                err "Last 10 lines of the log:"
                err "$(tail -10 $TMP_DIR/$DB.log)"
                exit $E_BACKUP
            }
        
        log "$DB: done, tables: $(ls $MYSQL_BACKUP_DIR/$DB/*.txt | wc -l)"
        s3upload $DB &
    done
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
while getopts ":bra:3:c:d:t:w:" opt; do
    case $opt in
        b) MODE="backup";;
        r) MODE="restore"; ID="$OPTARG";;
        a) [ -f "$OPTARG" ] && source "$OPTARG";;
        3) S3_BUCKET="$OPTARG";;
        c) MYSQL_CREDS="--defaults-extra-file=$OPTARG";;
        d) DATABASES=$(echo $OPTARG | sed 's#,# #g');;
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

if [ $MODE == "backup" ]; then
    backup
    wait
else
    restore
fi

alert "$MODE $ID completed."
