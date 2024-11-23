#!/bin/bash

source /backup-scripts/pgenv.sh

# Env variables
MYDATE=$(date +%d-%B-%Y)
MONTH=$(date +%B)
YEAR=$(date +%Y)
MYBASEDIR=/${BUCKET}
MYBACKUPDIR=${MYBASEDIR}/${YEAR}/${MONTH}
mkdir -p ${MYBACKUPDIR}
pushd ${MYBACKUPDIR} || exit



function dump_tables() {

    DATABASE=$1

    # Retrieve table names
    array=($(PGPASSWORD=${POSTGRES_PASS} psql ${PG_CONN_PARAMETERS} -d ${DATABASE} -At -F '.' -c "SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'pg_catalog', 'topology') AND table_name NOT IN ('raster_columns', 'raster_overviews', 'spatial_ref_sys', 'geography_columns', 'geometry_columns') ORDER BY table_schema, table_name;"))

    for i in "${array[@]}"; do

        IFS='.' read -r -a strarr <<< "$i"
        SCHEMA_NAME="${strarr[0]}"
        TABLE_NAME="${strarr[1]}"

        # Combine schema and table name
        DB_TABLE="${SCHEMA_NAME}.${TABLE_NAME}"
        # Check dump format
        if [[ ${DUMP_ARGS} == '-Fc' ]]; then
            FORMAT='dmp'
        else
            FORMAT='sql'
        fi

        # Construct filename
        FILENAME="${DUMPPREFIX}_${DB_TABLE}_${MYDATE}.${FORMAT}"

        # Log the backup start time
        echo -e "Backup of \e[1;31m ${DB_TABLE} \033[0m from DATABASE \e[1;31m ${DATABASE} \033[0m starting at \e[1;31m $(date) \033[0m" >> ${CONSOLE_LOGGING_OUTPUT}

        export PGPASSWORD=${POSTGRES_PASS}

        # Dump command
        if [[ "${DB_DUMP_ENCRYPTION}" =~ [Tt][Rr][Uu][Ee] ]]; then
            # Encrypted backup
            pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d "${DATABASE}" -t "${DB_TABLE}" | openssl enc -aes-256-cbc -pass pass:${DB_DUMP_ENCRYPTION_PASS_PHRASE} -pbkdf2 -iter 10000 -md sha256 -out "${FILENAME}"
            if [[ $? -ne 0 ]];then
             echo -e "Backup of \e[0;32m ${DB_TABLE} \033[0m from DATABASE \e[0;32m ${DATABASE} \033[0m failed" >> ${CONSOLE_LOGGING_OUTPUT}
            fi
        else
            # Plain backup
            pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d "${DATABASE}" -t "${DB_TABLE}" > "${FILENAME}"
            if [[ $? -ne 0 ]];then
             echo -e "Backup of \e[0;32m ${DB_TABLE} \033[0m from DATABASE \e[0;32m ${DATABASE} \033[0m failed" >> ${CONSOLE_LOGGING_OUTPUT}
            fi
        fi

        # Log the backup completion time
        echo -e  "Backup of \e[1;33m ${DB_TABLE} \033[0m from DATABASE \e[1;33m ${DATABASE} \033[0m completed at \e[1;33m $(date) \033[0m" >> ${CONSOLE_LOGGING_OUTPUT}

    done
}


function backup_db() {
  EXTRA_PARAMS=''
  if [ -n "$1" ]; then
    EXTRA_PARAMS=$1
  fi
  for DB in ${DBLIST}; do
    if [ -z "${ARCHIVE_FILENAME:-}" ]; then
      export FILENAME=${MYBACKUPDIR}/${DUMPPREFIX}_${DB}.${MYDATE}.dmp
    else
      export FILENAME=${MYBASEDIR}/"${ARCHIVE_FILENAME}.${DB}.dmp"
    fi

    if [[ "${DB_TABLES}" =~ [Ff][Aa][Ll][Ss][Ee] ]]; then
      export PGPASSWORD=${POSTGRES_PASS}
      echo -e "Backup  of \e[1;31m ${DB} \033[0m starting at \e[1;31m $(date) \033[0m" >> ${CONSOLE_LOGGING_OUTPUT}
      if [[ "${DB_DUMP_ENCRYPTION}" =~ [Tt][Rr][Uu][Ee] ]];then
        pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d ${DB} | openssl enc -aes-256-cbc -pass pass:${DB_DUMP_ENCRYPTION_PASS_PHRASE} -pbkdf2 -iter 10000 -md sha256 -out ${FILENAME}
      else
        pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d ${DB} > ${FILENAME}
      fi
      echo -e "Backup of \e[1;33m ${DB} \033[0m completed at \e[1;33m $(date) \033[0m and dump located at \e[1;33m ${FILENAME} \033[0m " >> ${CONSOLE_LOGGING_OUTPUT}

      dump_tables ${DB}
      if [[ ${STORAGE_BACKEND} == "S3" ]]; then
        ${EXTRA_PARAMS}
        rm ${MYBACKUPDIR}/*
      fi
    fi
  done

}


if [[ ${STORAGE_BACKEND} =~ [Ff][Ii][Ll][Ee] ]]; then
  # Backup globals Always get the latest
  PGPASSWORD=${POSTGRES_PASS} pg_dumpall ${PG_CONN_PARAMETERS}  --globals-only -f ${MYBASEDIR}/globals.sql
  # Loop through each pg database backing it up
  backup_db ""
fi


if [ "${REMOVE_BEFORE:-}" ]; then
  TIME_MINUTES=$((REMOVE_BEFORE * 24 * 60))
  if [[ ${STORAGE_BACKEND} == "FILE" ]]; then
    echo "Removing following backups older than ${REMOVE_BEFORE} days" >> ${CONSOLE_LOGGING_OUTPUT}
    find ${MYBASEDIR}/* -type f -mmin +${TIME_MINUTES} -delete & >> ${CONSOLE_LOGGING_OUTPUT}
  fi
fi
