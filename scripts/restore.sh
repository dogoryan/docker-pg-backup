#!/bin/bash

source /backup-scripts/pgenv.sh
POSTGRES_MAJOR_VERSION=$(cat /tmp/pg_version.txt)
BIN_DIR="/usr/lib/postgresql/${POSTGRES_MAJOR_VERSION}/bin/"

function terminate_connections() {
    echo "Terminating existing connections to ${RESTORE_TARGET_POSTGRES_DB}..."
    PGPASSWORD=${RESTORE_TARGET_POSTGRES_PASS} psql ${RESTORE_PG_CONN_PARAMETERS} -d postgres -c "
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = '${RESTORE_TARGET_POSTGRES_DB}'
        AND pid <> pg_backend_pid();"
    
    # Проверяем, остались ли активные соединения
    local connections
    connections=$(PGPASSWORD=${RESTORE_TARGET_POSTGRES_PASS} psql ${RESTORE_PG_CONN_PARAMETERS} -d postgres -t -c "
        SELECT COUNT(*)
        FROM pg_stat_activity
        WHERE datname = '${RESTORE_TARGET_POSTGRES_DB}'
        AND pid <> pg_backend_pid();")
    
    if [ "$connections" -gt 0 ]; then
        echo "Warning: Still have $connections active connections. Waiting..."
        sleep 5
        terminate_connections
    fi
}

function file_restore() {
    echo "RESTORE_TARGET_POSTGRES_DB: ${RESTORE_TARGET_POSTGRES_DB}"
    echo "TARGET_ARCHIVE: ${TARGET_ARCHIVE}"

    if [ -z "${TARGET_ARCHIVE:-}" ] || [ ! -f "${TARGET_ARCHIVE:-}" ]; then
        echo "TARGET_ARCHIVE needed."
        exit 1
    fi

    if [ -z "${RESTORE_TARGET_POSTGRES_DB:-}" ]; then
        echo "RESTORE_TARGET_POSTGRES_DB needed."
        exit 1
    fi

    # Завершаем все соединения перед удалением базы
    terminate_connections

    echo "Dropping target DB"
    PGPASSWORD=${RESTORE_TARGET_POSTGRES_PASS} dropdb ${RESTORE_PG_CONN_PARAMETERS} --if-exists ${RESTORE_TARGET_POSTGRES_DB}

    echo "Creating new database"
    PGPASSWORD=${RESTORE_TARGET_POSTGRES_PASS} createdb ${RESTORE_PG_CONN_PARAMETERS} ${RESTORE_TARGET_POSTGRES_DB}

    echo "Restoring dump file"
    if [[ "${DB_DUMP_ENCRYPTION}" =~ [Tt][Rr][Uu][Ee] ]]; then
        openssl enc -d -aes-256-cbc -pass pass:${DB_DUMP_ENCRYPTION_PASS_PHRASE} -pbkdf2 -iter 10000 -md sha256 -in ${TARGET_ARCHIVE} -out /tmp/decrypted.dump.gz | \
        PGPASSWORD=${RESTORE_TARGET_POSTGRES_PASS} pg_restore ${RESTORE_PG_CONN_PARAMETERS} \
            --no-owner \
            --no-acl \
            /tmp/decrypted.dump.gz \
            -d ${RESTORE_TARGET_POSTGRES_DB} \
            ${RESTORE_ARGS}
        rm /tmp/decrypted.dump.gz
    else
        PGPASSWORD=${RESTORE_TARGET_POSTGRES_PASS} pg_restore ${RESTORE_PG_CONN_PARAMETERS} \
            --no-owner \
            --no-acl \
            ${TARGET_ARCHIVE} \
            -d ${RESTORE_TARGET_POSTGRES_DB} \
            ${RESTORE_ARGS}
    fi
}

if [[ ${STORAGE_BACKEND} =~ [Ff][Ii][Ll][Ee] ]]; then
    file_restore
fi