#!/bin/bash

#version 0.8.2

#================================================
#Settings section
#================================================
STORAGE_DIR=/s3fs_backup/
REGULAR_DB_STORAGE_DIR="$STORAGE_DIR"/"$(hostname)"/regular/DB/
MONTHLY_DB_STORAGE_DIR="$STORAGE_DIR"/"$(hostname)"/monthly/DB/
REGULAR_FILES_STORAGE_DIR="$STORAGE_DIR"/"$(hostname)"/regular/files/
MONTHLY_FILES_STORAGE_DIR="$STORAGE_DIR"/"$(hostname)"/monthly/files/
#DAY_OF_WEEK=7
KEEP_FILES_DAYS=40
KEEP_DB_DAYS=40
NUMBER_OF_MONTH_BACKUP=10
PARALLEL_BACKUP_EXECUTION_CHECK=true
DAY_OF_WEEK=$(date +%u)
ERROR_LOG=/var/log/backup/error.log
BACKUP_LOG=/var/log/backup/backup.log
LOG_FORMAT=$(echo "$(date '+%b %d %r') $(hostname) $(whoami)") # дек 03 07:48:37  myserver user
BACKUP_DATE_FORMAT=$(date +%d%m%y_%H%M)_"$DAY_OF_WEEK" #DIRECTORY_031222_2118_1.tar.gz
MYSQL_IGNORE_DB="(^mysql|schema|roundcube|phpmyadmin|sys$)" # regexp
PSQL_INGONRE_DB="postgres,template0,template1" #values through ","
#================================================




#================================================
#Functions section
#================================================

#Help section
usage () {
cat << EOF
Backup scrypt for directory and mysql/postgres databases
Don't use DB backup and dirrecotry backup together

To configure, edit settings section inside the scrypt:
STORAGE_DIR - backup directory
KEEP_FILES_DAYS - how long to keep files in days
KEEP_DB_DAYS - how long to keep databases in days
NUMBER_OF_MONTH_BACKUP - how long to keep month backup files in month (1-12)
PARALLEL_BACKUP_EXECUTION_CHECK - f you want to run multiple backups on the server at the same time set to false
ERROR_LOG=error.log - path to error log file
BACKUP_LOG=backup.log - path to info log file
MYSQL_IGNORE_DB="(^mysql|schema$)" - mysql databases that will not be copied, regexp
PSQL_INGONRE_DB="postgres,template0,template1" - postgresl databases that will not be copied, values through ","

usage:
sdbackup -b /MY_TEMP_ARCHIVE_DIRECTORY -d [DIRECTORY_YOU_WANT_TO_BACK_UP]
sdbackup -b /MY_TEMP_ARCHIVE_DIRECTORY -f [DIRECTORY_LIST_FILE]
sdbackup -db

-b,     - Set temp archive directory
-d,     - Set backup directory (don't use together vs -f)
-f,     - Set directory backup list (don't use together vs -d), last string need to be empty
-db,    - Create database backup, don't use DB and directory backup together -f or -d, don't forget edit *_IGNORE_DB settings
-h,     - Show this help
EOF
}

MONTH_TO_DAY=$(( ( $(date '+%s') - $(date -d "$NUMBER_OF_MONTH_BACKUP months ago" '+%s') ) / 86400 ))

error_logger () {
    echo "$LOG_FORMAT - Error: $(echo "$1" | sed 's/\/\//\//g')" >> $ERROR_LOG
}

info_logger () {
    echo "$LOG_FORMAT - Info: $(echo "$1" | sed 's/\/\//\//g')" >> $BACKUP_LOG
}

#Set custom temp archive directory, сheck directory for existence
set_temp_archive_directory () {
    if [ -z "$1" ]
        then
            error_logger "backup temp archive directory is not set, use -b /PATH_TO_BACKUP_ARCHIVE_FOLDER"
            exit 1
    elif [ ! -d "$1" ]
        then
            error_logger "$1 is not directory"
            exit 1
    fi

    TEMP_ARCHIVE_DIR="$1"/$(hostname)

    if [ ! -d "$TEMP_ARCHIVE_DIR" ]
        then
            mkdir -p "$TEMP_ARCHIVE_DIR"
            info_logger "create temp archive directory - $TEMP_ARCHIVE_DIR"
    fi

    info_logger "set temp archive directory to $TEMP_ARCHIVE_DIR"
}

#Set custom backup directory, сheck directory for existence
set_backup_directory () {
    if [ -n "$BACKUP_LIST" ] || [ -n "$DB_BACKUP" ]
        then
            error_logger "BACKUP_LIST is exist = $BACKUP_LIST, do not use -f and -d together"
            exit 1
    elif [ -z "$1" ]
        then
            error_logger "backup directory is not set, use -b /PATH_TO_DATA"
            exit 1
    elif [ ! -d "$1" ]
        then
            error_logger "$1 is not directory"
            exit 1
    fi

    BACKUP_DIR="$1"
    info_logger "set backup directory to $BACKUP_DIR"
}

#Set data directories from file
set_backup_list () {
    if [ -n "$BACKUP_DIR" ] || [ -n "$DB_BACKUP" ]
        then
            error_logger "BACKUP_DIR or DB_BACKUP is exist = $DB_BACKUP$BACKUP_DIR, do not use -f, -d and -db together"
            exit 1
    elif [ -z "$1" ]
        then
            error_logger "backup list is not set, use -f /PATH_TO_BACKUP_LIST_FILE"
            exit 1
    elif [ ! -f "$1" ]
        then
            error_logger "$1 is not a file"
            exit 1
    fi

    BACKUP_LIST="$1"
    info_logger "set backup list file to $BACKUP_LIST"
}

set_db_backup_true () {
    if [ -n "$BACKUP_DIR" ] || [ -n "$BACKUP_LIST" ]
        then
            error_logger "file backup and database backup options exist together. Don't use "-db" together vs "-d" or "-f""
            exit 1
    elif [ -z "$1" ]
        then
            error_logger "database in not set, use -db DBname"
            exit 1
    fi

    DB_BACKUP=true
}

#genetate database list from mysql and postgresql without ignore db in settings section
get_database_list () {
    #Check postgresql is exist
    if psql -V > /dev/null
        then
            #select all postgres database without ignire list
            IFS=','
            read -r -a ignore_db_array <<< "$PSQL_INGONRE_DB"
            su postgres -c "psql -l -t | cut -d'|' -f1 | sed -e 's/ //g' -e '/^$/d'" > "$TEMP_ARCHIVE_DIR"/postgres_db_list
            for ignore_db_name in "${ignore_db_array[@]}"
                do
                    ignore_db_name=$(echo "$ignore_db_name" | sed -e 's/ //g')
                    sed -i "/^$ignore_db_name$/d" "$TEMP_ARCHIVE_DIR"/postgres_db_list
            done;
        else
            error_logger "get db list, pgsql is not installed"
    fi

    #Check mysql is exist
    if mysql -V > /dev/null
        then
            #select all postgres database without ignire list
            for dbname in $(sudo -u root mysql -e "SHOW DATABASES WHERE \`Database\` NOT REGEXP '$MYSQL_IGNORE_DB';" | awk -F " " '{if (NR!=1) print $1}')
                do
                    echo "$dbname" > "$TEMP_ARCHIVE_DIR"/mysql_db_list
            done
        else
            error_logger "get db list, mysql is not installed"
    fi
}

backup_batabases () {
    if [ -f "$TEMP_ARCHIVE_DIR"/mysql_db_list ]
        then
            while read -r DATABASE
            do
                sudo -u root mysqldump "$DATABASE" | gzip -6 > "$TEMP_ARCHIVE_DIR"/"$DATABASE"_"$BACKUP_DATE_FORMAT".msql.gz
                info_logger "create mysql DB archive - $TEMP_ARCHIVE_DIR/${DATABASE}_$BACKUP_DATE_FORMAT.msql.gz"
            done < "$TEMP_ARCHIVE_DIR"/mysql_db_list
    fi
    if [ -f "$TEMP_ARCHIVE_DIR"/postgres_db_list ]
        then
            while read -r DATABASE
            do
                su postgres -c "pg_dump $DATABASE" | gzip -6 > "$TEMP_ARCHIVE_DIR"/"$DATABASE"_"$BACKUP_DATE_FORMAT".psql.gz
                info_logger "create postgres DB archive - $TEMP_ARCHIVE_DIR/${DATABASE}_$BACKUP_DATE_FORMAT.psql.gz"
            done < "$TEMP_ARCHIVE_DIR"/postgres_db_list
    fi
}


#If another backup process is running, wait 10 min x6 then break backup
parallel_execution_check () {
    if [ "$PARALLEL_BACKUP_EXECUTION_CHECK" == true ]
        then
            i=0
            while [ -f /tmp/backup.pid ]
                do
                    if [ $i -eq 5 ]
                        then
                            error_logger "another backup is runing pid = $(cat /tmp/backup.pid)"
                            exit 1
                        else
                            sleep 600
                            (( i++ ))
                    fi
                done
        echo $$ > /tmp/backup.pid
    fi
}

#create differential directory archive
create_regular_file_archive () {
    tar \
        --create \
        --gzip \
        --file="$TEMP_ARCHIVE_DIR/$(basename "$BACKUP_DIR")_$BACKUP_DATE_FORMAT.tar.gz" \
        --ignore-failed-read \
        --listed-incremental="$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential.snar \
        -C $(dirname "$BACKUP_DIR") $(basename "$BACKUP_DIR")
    info_logger "create directory archive - $(basename "$BACKUP_DIR")_$BACKUP_DATE_FORMAT.tar.gz from $BACKUP_DIR"
}

create_monthly_file_archive () {
    tar \
        --create \
        --gzip \
        --file="$TEMP_ARCHIVE_DIR/$(basename "$BACKUP_DIR")_$BACKUP_DATE_FORMAT.tar.gz" \
        --ignore-failed-read \
        -C $(dirname "$BACKUP_DIR") $(basename "$BACKUP_DIR")
    info_logger "create directory archive - $(basename "$BACKUP_DIR")_$BACKUP_DATE_FORMAT.tar.gz from $BACKUP_DIR"
}



#Differential backup section
differential () {
    DIRECTORY_NAME=$(basename "$BACKUP_DIR")
    #remove current metadata file
    rm -f "$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential.snar

    #if sunday delete start metadata copy file
    if [ "$DAY_OF_WEEK" -eq 7 ]
        then
            rm -f "$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential_7.snar
        else [ -f "$TEMP_ARCHIVE_DIR"/differential_7.snar ]
            cp "$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential_7.snar "$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential.snar
    fi

    create_regular_file_archive

    #create copy of start metadata file
    if [ "$DAY_OF_WEEK" -eq 7 ]
        then
            cp "$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential.snar "$TEMP_ARCHIVE_DIR"/"$DIRECTORY_NAME"_differential_7.snar
    fi

}

# create files backup
create_files_backup () {
    if [ -n "$BACKUP_LIST" ]
        then
            while read -r DIR
                do
                    if [ ! -e "$DIR" ]
                        then
                            error_logger "$DIR in not exist, check backup list - $BACKUP_LIST"
                            continue
                    fi

                    BACKUP_DIR="$DIR"
                    differential
            done < "$BACKUP_LIST"
        else
            differential
    fi
}

#checking the existence of a directory
directories_existnce_check () {
    if [ ! -d "$REGULAR_DB_STORAGE_DIR" ]
        then
            mkdir -p "$REGULAR_DB_STORAGE_DIR"
            info_logger "regular DB BACKUP_STORAGE_DIR is not exist, create $REGULAR_DB_STORAGE_DIR"
    fi
    if [ ! -d "$REGULAR_FILES_STORAGE_DIR" ]
        then
            mkdir -p "$REGULAR_FILES_STORAGE_DIR"
            info_logger "regular files BACKUP_STORAGE_DIR is not exist, create $REGULAR_FILES_STORAGE_DIR"
    fi
    if [ ! -d "$MONTHLY_DB_STORAGE_DIR" ]
        then
            mkdir -p "$MONTHLY_DB_STORAGE_DIR"
            info_logger "month DB STORAGE_DIR is not exist, create $MONTHLY_DB_STORAGE_DIR"
    fi
    if [ ! -d "$MONTHLY_FILES_STORAGE_DIR" ]
        then
            mkdir -p "$MONTHLY_FILES_STORAGE_DIR"
            info_logger "month files STORAGE_DIR is not exist, create $MONTHLY_FILES_STORAGE_DIR"
    fi

    if [ -n "$BACKUP_LIST" ]
        then
            while read -r DIR
                do
                    if [ ! -d "$REGULAR_FILES_STORAGE_DIR"/$(basename $DIR) ]
                        then
                            mkdir -p "$REGULAR_FILES_STORAGE_DIR"/$(basename $DIR)
                            info_logger "regular backup directory $(basename $DIR) does not exist, create directory"
                    fi
                    if [ ! -d "$MONTHLY_FILES_STORAGE_DIR"/$(basename $DIR) ]
                        then
                            mkdir -p "$MONTHLY_FILES_STORAGE_DIR"/$(basename $DIR)
                            info_logger "monthly backup directory $(basename $DIR) does not exist, create directory"
                    fi
            done < "$BACKUP_LIST"
        else
            if [ ! -d "$REGULAR_FILES_STORAGE_DIR"/$(basename $BACKUP_DIR) ]
                then
                    mkdir -p "$REGULAR_FILES_STORAGE_DIR"/$(basename $BACKUP_DIR)
                    info_logger "regular backup directory $(basename $BACKUP_DIR) does not exist, create directory"
            fi
            if [ ! -d "$MONTHLY_FILES_STORAGE_DIR"/$(basename $BACKUP_DIR) ]
                then
                    mkdir -p "$MONTHLY_FILES_STORAGE_DIR"/$(basename $BACKUP_DIR)
                    info_logger "monthly backup directory $(basename $BACKUP_DIR) does not exist, create directory"
            fi
    fi
    while read -r BASE
        do
            if [ ! -d "$REGULAR_DB_STORAGE_DIR"/"$BASE" ]
                then
                    mkdir -p "$REGULAR_DB_STORAGE_DIR"/"$BASE"
                    info_logger "regular DB directory $BASE does not exist, create directory"
            fi
            if [ ! -d "$MONTHLY_DB_STORAGE_DIR"/"$BASE" ]
                then
                    mkdir -p "$MONTHLY_DB_STORAGE_DIR"/"$BASE"
                    info_logger "monthly DB directory $BASE does not exist, create directory"
            fi
    done < "$TEMP_ARCHIVE_DIR"/postgres_db_list
    while read -r BASE
        do
            if [ ! -d "$REGULAR_DB_STORAGE_DIR"/"$BASE" ]
                then
                    mkdir -p "$REGULAR_DB_STORAGE_DIR"/"$BASE"
                    info_logger "regular DB directory $BASE does not exist, create directory"
            fi
            if [ ! -d "$MONTHLY_DB_STORAGE_DIR"/"$BASE" ]
                then
                    mkdir -p "$MONTHLY_DB_STORAGE_DIR"/"$BASE"
                    info_logger "monthly DB directory $BASE does not exist, create directory"
            fi
    done < "$TEMP_ARCHIVE_DIR"/mysql_db_list    
}
#copy archive to backup storage directory
move_backup () {
    directories_existnce_check
    #copy *.tar.gz files
    #copy monthly backup files, if files not exist
    if [[ $(date +%d) == 01 ]] && ! ls "$MONTHLY_FILES_STORAGE_DIR"/*/*_01"$(date +%m)"??_* > /dev/null && [ -z "$DB_BACKUP" ]
        then
            for files in "$TEMP_ARCHIVE_DIR"/*.tar.gz
                do
                    cp -p "$files" "$MONTHLY_FILES_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    info_logger "copy $files to $MONTHLY_FILES_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    rm -f "$files"
            done
        else
    #copy regular files backup
        if [ -z "$DB_BACKUP" ]
        then
            for files in "$TEMP_ARCHIVE_DIR"/*.tar.gz
                do
                    cp -p "$files" "$REGULAR_FILES_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    info_logger "copy $files to $REGULAR_FILES_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    rm -f "$files"
            done
        fi
    fi

    #copy monthly DB, if files not exist
    if [[ $(date +%d) == 01 ]] && ! ls "$MONTHLY_DB_STORAGE_DIR"/*/*_01"$(date +%m)"??_*.?sql.gz > /dev/null && [ -n "$DB_BACKUP" ]
        then
            for files in "$TEMP_ARCHIVE_DIR"/*.{msql,psql}.gz
                do
                    cp -p "$files" "$MONTHLY_DB_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    info_logger "copy $files to $MONTHLY_DB_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    rm -f "$files"
            done
        else
    #copy regular DB backup
        if [ -n "$DB_BACKUP" ]
        then    
            for files in "$TEMP_ARCHIVE_DIR"/*.{msql,psql}.gz
                do
                    cp -p "$files" "$REGULAR_DB_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    info_logger "copy $files to $REGULAR_DB_STORAGE_DIR/$(echo $(basename $files) | sed -E 's/_[0-9]{6}_[0-9]{4}_[0-7].*.gz//')"
                    rm -f "$files"
            done
        fi
    fi
}
#delete old file in backup storage dir
delete_old_files () {
    if [ -n "$BACKUP_LIST" ]
        then
            while read -r DIR
                do
                    file_name=$(basename "$DIR")
                    find "$REGULAR_FILES_STORAGE_DIR" -name "$file_name*" -mtime +"$KEEP_FILES_DAYS" -delete
                    find "$MONTHLY_FILES_STORAGE_DIR" -name "$file_name*" -mtime +"$MONTH_TO_DAY" -delete
            done < "$BACKUP_LIST"
        else
            file_name=$(basename "$BACKUP_DIR")
            find "$REGULAR_FILES_STORAGE_DIR" -name "$file_name*" -mtime +"$KEEP_FILES_DAYS" -delete
            find "$MONTHLY_FILES_STORAGE_DIR" -name "$file_name*" -mtime +"$MONTH_TO_DAY" -delete
    fi
}

#delete old databases in backup storage dir
delete_old_database () {
    if [ -f "$TEMP_ARCHIVE_DIR"/postgres_db_list ]
        then
            while read -r DATABASE
                do
                    find "$REGULAR_DB_STORAGE_DIR" -name "$DATABASE"'_*.psql.gz' -mtime +"$KEEP_DB_DAYS" -delete
            done < "$TEMP_ARCHIVE_DIR"/postgres_db_list
            #rm "$TEMP_ARCHIVE_DIR"/postgres_db_list
    fi
    if [ -f "$TEMP_ARCHIVE_DIR"/mysql_db_list ]
        then
            while read -r DATABASE
                do
                    find "$REGULAR_DB_STORAGE_DIR" -name "$DATABASE"'_*.msql.gz' -mtime +"$KEEP_DB_DAYS" -delete
            done < "$TEMP_ARCHIVE_DIR"/mysql_db_list
            #rm "$TEMP_ARCHIVE_DIR"/mysql_db_list
    fi
}

monthly_backup () {
    if [ -n "$BACKUP_LIST" ]
        then
            while read -r DIR
                do
                    if [ ! -e "$DIR" ]
                        then
                            error_logger "$DIR in not exist, check backup list - $BACKUP_LIST"
                            continue
                    fi

                    BACKUP_DIR="$DIR"

                    if [[ $(date +%d) == 01 ]] && ! ls "$MONTHLY_FILES_STORAGE_DIR"/$(basename "$BACKUP_DIR")/$(basename "$BACKUP_DIR")*_01"$(date +%m)"??_* > /dev/null && [ -z "$DB_BACKUP" ]
                        then
                            create_monthly_file_archive
                    fi

            done < "$BACKUP_LIST"

        elif [[ $(date +%d) == 01 ]] && ! ls "$MONTHLY_FILES_STORAGE_DIR"/$(basename "$BACKUP_DIR")/$(basename "$BACKUP_DIR")*_01"$(date +%m)"??_* > /dev/null && [ -z "$DB_BACKUP" ]
            then
                create_monthly_file_archive
    fi
    if [[ $(date +%d) == 01 ]] && ! ls "$MONTHLY_DB_STORAGE_DIR"/*/*_01"$(date +%m)"??_*.?sql.gz > /dev/null && [ -n "$DB_BACKUP" ]
        then
            get_database_list
            backup_batabases
            move_backup
    fi
}

regular_backup () {
    parallel_execution_check

    if [ -z "$DB_BACKUP" ]
        then
            create_files_backup
            delete_old_files
    fi

    if [ "$PARALLEL_BACKUP_EXECUTION_CHECK" == true ]
        then
            rm -f /tmp/backup.pid
    fi

    if [ -n "$DB_BACKUP" ]
        then
            get_database_list
            backup_batabases
            delete_old_database
    fi

    move_backup
}

#================================================




#================================================
#Main section
#================================================
if [ $# -eq 0 ]
    then
        echo "$LOG_FORMAT - Error: No input option passed"
        echo "Usage: sdbackup [OPTIONS]"
        usage
        exit 1
fi

while [ -n "$1" ]
do
    case "$1" in
        -b) set_temp_archive_directory "$2"
        shift ;;
        -d) set_backup_directory "$2"
        shift;;
        -f) set_backup_list "$2"
        shift;;
        -db) set_db_backup_true "$1"
        ;;
        -h) usage
        shift;;
        *) echo "wrong argument"
        exit 1;;
    esac
    shift
done


monthly_backup
regular_backup

#================================================
