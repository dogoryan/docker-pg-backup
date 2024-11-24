# To run 

clone repo
```
git clone git@github.com:dogoryan/docker-pg-backup.git
```
--- 
copy .example.env to .env and set variables
```
cp .example.env .env
```
--- 
build image
```
./build.sh
```
---
run container
```
docker compose up -d
``` 

# Restore

В .env указываем нужные параметры базы для восстановления (RESTORE_TARGET_POSTGRES_***)


```
TARGET_ARCHIVE=/backups/2024/November/PG_postgres.24-November-2024.dmp \
RESTORE_TARGET_POSTGRES_DB=your_database \
./restore.sh
```
