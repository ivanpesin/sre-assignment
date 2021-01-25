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
TOOLS="aws curl mail mydumper myloader pv"
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
    -l          list backups available for restore
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

# alert() sends notifications to selected slack and email address
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

# logging functions; err is for critical errors, sends alerts automatically
log() { echo "$(date -Is): $*"; }
err() { echo "$(date -Is): ERR: $*" >&2; alert ":exclamation: $MODE $BACKUP_TS: ERROR: $*"; }

# check_config() verifies access, tools, directories needed for operation
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

# check_node() does basic sanity checks: free space, cpu load, swap, network connectivity
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

# cleanup() removes temporary files and spawned processes
cleanup() {
    trap '' EXIT INT HUP
    log "Running cleanup..."
   
    # kill all child processes
    kill $(ps -s $$ -o pid=) 2>/dev/null || :
    # remove temp directory
    [[ ! -z "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || :

    log "Cleanup done"
}

# this background function monitors backup directory and outputs stats
backup_progress() {
    
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

# s3upload uploads backup to s3 bucket
s3upload() {
    [ -z "$S3_BUCKET" ] && return # skipping upload if bucket is set to empty string

    log "[s3upload] Uploading $BACKUP_TS backup to $S3_BUCKET ..."
    log "[s3upload] Schema:"
    tar cf - -C "$MYSQL_BACKUP_DIR" "${BACKUP_TS}-schema" | pv | \
       aws s3 cp - "$S3_BUCKET/${BACKUP_TS}-schema.tar" && {
           rm -rf "$MYSQL_BACKUP_DIR/${BACKUP_TS}-schema"; 
       } || {
           err "[s3upload] Failed to upload schema backup to $S3_BUCKET; leaving it on disk."
       }

    log "[s3upload] Full:"
    tar cf - -C "$MYSQL_BACKUP_DIR" "${BACKUP_TS}" | pv | \
       aws s3 cp - "$S3_BUCKET/${BACKUP_TS}.tar" && {
           rm -rf "$MYSQL_BACKUP_DIR/${BACKUP_TS}"; 
       } || {
           err "[s3upload] Failed to upload full backup to $S3_BUCKET; leaving it on disk."
       }
}

# backup() performs parallelized and compressed logical backup, and then separates 
#          schema definition into separate directory for upload
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
    mkdir $MYSQL_BACKUP_DIR/${BACKUP_TS}-schema && \
      cp $MYSQL_BACKUP_DIR/$BACKUP_TS/metadata $MYSQL_BACKUP_DIR/${BACKUP_TS}-schema && \
      cp $MYSQL_BACKUP_DIR/$BACKUP_TS/*schema* $MYSQL_BACKUP_DIR/${BACKUP_TS}-schema || {
      # ^^^ might want to 'mv' instead, so that data restore does not recreate schema
        err "Failed to create schema backup directory"; 
        exit $E_BACKUP_DIR
    }
        

    s3upload
}

s3download() {

    [ -z "$S3_BUCKET" ] && return

    local fn=$1
    
    log "[s3download] Downloading $fn ..."
    aws s3 cp $S3_BUCKET/$fn - | tar xf - -C "$MYSQL_BACKUP_DIR"  || :
    log "[s3download] Downloaded: $fn"
}

# restore() performs schema restore and check, then data restore and check; after that
#           it runs SQL queries to ensure data restoration correctness
restore() {
    local PHASES=5
    local restore_log="$MYSQL_BACKUP_DIR/${BACKUP_TS}-restore.log"
    local backup_log="$MYSQL_BACKUP_DIR/${BACKUP_TS}-backup.log"
    local check_log="$MYSQL_BACKUP_DIR/${BACKUP_TS}-check.log"

    log "Restoring $BACKUP_TS backup ..."

    [ -d "$MYSQL_BACKUP_DIR/${BACKUP_TS}" ] || s3download "${BACKUP_TS}.tar" &
    [ -d "$MYSQL_BACKUP_DIR/${BACKUP_TS}-schema" ] || s3download "${BACKUP_TS}-schema.tar"
    
# test 1: restore schema only and check for errors
    log "[1/$PHASES] Restoring schema ..."
    myloader $MYSQL_CREDS \
        -d "$MYSQL_BACKUP_DIR/${BACKUP_TS}-schema" \
        -o -t $THR> "$restore_log" 2>&1 &
    pid=$!

    pv -d $pid && wait $pid || {
        err "Failed to restore schema from ${BACKUP_TS} backup"
        tail -10 "$restore_log" >&2
        exit $E_BACKUP
    }

    log "[2/$PHASES] Checking schema: "
    mysqlcheck $MYSQL_CREDS --all-databases > "$check_log" 2>&1 || {
        err "Schema restored with issues. Last 10 lines of the log:"
        tail -10 "$check_log" >&2
        exit $E_BACKUP
    }
    log "Tables OK: $(awk '/OK$/{ok++}END{print ok "/" NR}' $check_log)"

# test 2: restore data and check for errors
    log "Waiting for data download to complete..."
    wait # for s3download of data
    log "[3/$PHASES] Restoring data ..."
    echo "$(date -Is) --- Full restoration log ---" >> "$restore_log" 
    myloader $MYSQL_CREDS \
        -d "$MYSQL_BACKUP_DIR/${BACKUP_TS}" \
        -o -t $THR >> "$restore_log" 2>&1 &
    pid=$!
    pv -d $pid && wait $pid || {
            err "Failed to restore data from ${BACKUP_TS} backup"
            tail -10 "$restore_log" >&2
            exit $E_BACKUP
    }

    log "[4/$PHASES] Checking data: "
    mysqlcheck $MYSQL_CREDS --all-databases > "$check_log" 2>&1 || {
        err "Data restored with issues. Last 10 lines of the log:"
        tail -10 "$check_log" >&2
        exit $E_BACKUP
    }
    log "Tables OK: $(awk '/OK$/{ok++}END{print ok "/" NR}' $check_log)"

# test 3: check requiring knowledge of data, eg number of records in a table
#         matches the number of assets in a directory, checksumming, etc 
    log "[5/$PHASES] Data-specific integrity checks ... "

    # ex: pick 3 random tables from the backup and make sure number of records match
    local files=$(ls $MYSQL_BACKUP_DIR/${BACKUP_TS}/*.sql.gz | \
        egrep -v '/mysql\.|schema-create|schema\.sql\.gz|[0-9]\.sql\.gz$' | \
        shuf | tail -3)
    for file in $files; do
        local db_name=$(echo $file | sed 's#.*/##' | cut -d. -f1)
        local tbl_name=$(echo $file | sed 's#.*/##' | cut -d. -f2)
        local rcnt=$(zgrep -c '^(' $file)
        
        rcnt_actual=$(mysql $MYSQL_CREDS $db_name -NBe 'select count(*) from '"$tbl_name"';' || :)
        [ ! -z "$rcnt_actual" ] || {
            err "Failed to get row count for $db_name.$tbl_name"
            exit $E_BACKUP
        }

        if [ $rcnt -eq $rcnt_actual ]; then
            log "OK: $db_name.$tbl_name row counts match. Backup: $rcnt Actual: $rcnt_actual"
        else
            err "FAIL: $db_name.$tbl_name row counts differ! Backup: $rcnt Actual: $rcnt_actual"
            exit $E_BACKUP
        fi
    done

}

# list() displays available S3 backups for restore
list() {
    log "Retrieving available backups ..."
    local SCHEMAS=$(aws s3 ls "$S3_BUCKET" | grep 'schema.tar' || : )
    # technically should check both schema and data archives are available

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
while getopts "br:la:3:c:t:w:" opt; do
    case $opt in
        b) MODE="backup";;
        r) MODE="restore"; BACKUP_TS="$OPTARG";
           echo $BACKUP_TS | \
            egrep -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' || {
             err "Invalid backup timestamp specification: $BACKUP_TS"
             exit $E_SYNTAX
            };;
        l) MODE="list";;
        a) [ -f "$OPTARG" ] && source "$OPTARG";;
        3) S3_BUCKET="$OPTARG";;
        c) MYSQL_CREDS="--defaults-file=$OPTARG";;
        r) PART_ROWS=$OPTARG;;
        t) MYSQL_BACKUP_DIR="$OPTARG";;
        w) SLACK_WEBHOOK="$OPTARG";;
        ?|:) usage; exit $E_SYNTAX;; 
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
