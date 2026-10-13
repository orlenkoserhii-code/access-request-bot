#!/usr/bin/env bash
set -e

: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set ON_ERROR_STOP=1 --file=/bootstrap/init.sql

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set ON_ERROR_STOP=1 --set app_password="$APP_DB_PASSWORD" <<'SQL'
ALTER ROLE access_worker PASSWORD :'app_password';
SQL
