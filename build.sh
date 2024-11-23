#!/usr/bin/env bash

if [[ ! -f .env ]]; then
    echo "Error: .env file does not exist. Please create it from .example.env." >&2
    exit 1
else
    export $(grep -v '^#' .env | xargs)
fi

#Мб поставить образ пг? 
docker pull postgres:$POSTGRES_MAJOR_VERSION

if command -v docker-compose > /dev/null; then
  docker-compose -f docker-compose.yml build dbbackups
else
  docker compose -f docker-compose.yml build dbbackups
fi