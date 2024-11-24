#!/bin/bash

source /backup-scripts/pgenv.sh

# Функция логирования
log_message() {
    local level=$1
    local message=$2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "${CONSOLE_LOGGING_OUTPUT:-/dev/stdout}"
}

# Проверка необходимых переменных окружения
for var in POSTGRES_PASS POSTGRES_USER POSTGRES_HOST POSTGRES_PORT BUCKET; do
    if [ -z "${!var}" ]; then
        log_message "ERROR" "${var} is not set"
        exit 1
    fi
done

# Настройка директорий
MYDATE=$(date +%d-%B-%Y)
MONTH=$(date +%B)
YEAR=$(date +%Y)
MYBASEDIR="/${BUCKET}"
MYBACKUPDIR="${MYBASEDIR}/${YEAR}/${MONTH}"

# Создание директории для бэкапов
if [ ! -d "${MYBACKUPDIR}" ]; then
    mkdir -p "${MYBACKUPDIR}"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to create backup directory ${MYBACKUPDIR}"
        exit 1
    fi
fi

# Проверка прав на запись
if [ ! -w "${MYBACKUPDIR}" ]; then
    log_message "ERROR" "No write permission for ${MYBACKUPDIR}"
    exit 1
fi

# Переход в директорию бэкапов
pushd "${MYBACKUPDIR}" > /dev/null 2>&1 || {
    log_message "ERROR" "Failed to change directory to ${MYBACKUPDIR}"
    exit 1
}

function dump_tables() {
    local DATABASE=$1
    
    if [ -z "${DATABASE}" ]; then
        log_message "ERROR" "Database name not provided"
        return 1
    fi

    log_message "INFO" "Starting table dumps for database ${DATABASE}"

    # Получение списка таблиц
    local array
    array=($(psql ${PG_CONN_PARAMETERS} -d "${DATABASE}" -At -F '.' -c "
        SELECT table_schema, table_name 
        FROM information_schema.tables 
        WHERE table_schema NOT IN ('information_schema', 'pg_catalog', 'topology') 
        AND table_name NOT IN ('raster_columns', 'raster_overviews', 'spatial_ref_sys', 'geography_columns', 'geometry_columns') 
        ORDER BY table_schema, table_name;"))

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to get table list from database ${DATABASE}"
        return 1
    fi

    for i in "${array[@]}"; do
        IFS='.' read -r -a strarr <<< "$i"
        local SCHEMA_NAME="${strarr[0]}"
        local TABLE_NAME="${strarr[1]}"
        local DB_TABLE="${SCHEMA_NAME}.${TABLE_NAME}"
        
        # Определение формата файла
        local FORMAT
        if [[ ${DUMP_ARGS} == '-Fc' ]]; then
            FORMAT='dmp'
        else
            FORMAT='sql'
        fi

        local FILENAME="${DUMPPREFIX}_${DB_TABLE}_${MYDATE}.${FORMAT}"
        
        log_message "INFO" "Starting backup of table ${DB_TABLE}"

        if [[ "${DB_DUMP_ENCRYPTION}" =~ [Tt][Rr][Uu][Ee] ]]; then
            if ! pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d "${DATABASE}" -t "${DB_TABLE}" | \
                openssl enc -aes-256-cbc -pass pass:"${DB_DUMP_ENCRYPTION_PASS_PHRASE}" -pbkdf2 -iter 10000 -md sha256 -out "${FILENAME}"; then
                log_message "ERROR" "Failed to create encrypted backup of ${DB_TABLE}"
                continue
            fi
        else
            if ! pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d "${DATABASE}" -t "${DB_TABLE}" > "${FILENAME}"; then
                log_message "ERROR" "Failed to create backup of ${DB_TABLE}"
                continue
            fi
        fi

        # Установка безопасных прав на файл бэкапа
        chmod 600 "${FILENAME}"
        
        log_message "INFO" "Completed backup of table ${DB_TABLE}"
    done
}

function backup_db() {
    if [ -z "${DBLIST}" ]; then
        log_message "ERROR" "No databases specified in DBLIST"
        return 1
    fi

    for DB in ${DBLIST}; do
        if [ -z "${ARCHIVE_FILENAME:-}" ]; then
            FILENAME="${MYBACKUPDIR}/${DUMPPREFIX}_${DB}.${MYDATE}.dmp"
        else
            FILENAME="${MYBASEDIR}/${ARCHIVE_FILENAME}.${DB}.dmp"
        fi

        if [[ "${DB_TABLES}" =~ [Ff][Aa][Ll][Ss][Ee] ]]; then
            log_message "INFO" "Starting backup of database ${DB}"
            
            if [[ "${DB_DUMP_ENCRYPTION}" =~ [Tt][Rr][Uu][Ee] ]]; then
                if ! pg_dump ${PG_CONN_PARAMETERS} \
                    -Fc \
                    --clean \
                    --create \
                    --if-exists \
                    --no-owner \
                    --no-acl \
                    -d "${DB}" -f "${FILENAME}" | \
                    openssl enc -aes-256-cbc -pass pass:"${DB_DUMP_ENCRYPTION_PASS_PHRASE}" -pbkdf2 -iter 10000 -md sha256 -out "${FILENAME}"; then
                    log_message "ERROR" "Failed to create encrypted backup of ${DB}"
                    continue
                fi
            else
                if ! pg_dump ${PG_CONN_PARAMETERS} \
                    -Fc \
                    --clean \
                    --create \
                    --if-exists \
                    --no-owner \
                    --no-acl \
                    -d "${DB}" -f "${FILENAME}"; then
                    log_message "ERROR" "Failed to create backup of ${DB}"
                    continue
                fi
            fi

            chmod 600 "${FILENAME}"
            log_message "INFO" "Completed backup of database ${DB}"
            
            # Закомментируйте или удалите эту строку:
            # dump_tables "${DB}"
        fi
    done
}

# Очистка при выходе
cleanup() {
    rm -f /tmp/pg_dump_*
    popd > /dev/null 2>&1
}
trap cleanup EXIT

# Основной процесс бэкапа
if [[ ${STORAGE_BACKEND} =~ [Ff][Ii][Ll][Ee] ]]; then
    # Бэкап глобальных объектов
    log_message "INFO" "Starting backup of global objects"
    if ! pg_dumpall ${PG_CONN_PARAMETERS} --globals-only -f "${MYBASEDIR}/globals.sql"; then
        log_message "ERROR" "Failed to backup global objects"
    else
        chmod 600 "${MYBASEDIR}/globals.sql"
        log_message "INFO" "Completed backup of global objects"
    fi

    # Бэкап баз данных
    backup_db
fi

# Удаление старых бэкапов
if [ "${REMOVE_BEFORE:-}" ]; then
    TIME_MINUTES=$((REMOVE_BEFORE * 24 * 60))
    log_message "INFO" "Removing backups older than ${REMOVE_BEFORE} days"
    find "${MYBASEDIR}" -type f -mmin "+${TIME_MINUTES}" -delete 2>/dev/null || \
        log_message "WARNING" "Failed to remove some old backups"
fi