#!/bin/sh
set -eu
mkdir -p backups
chmod 700 backups
backup="backups/cc-assistant-$(date -u +%Y%m%dT%H%M%SZ).sqlite"
docker compose exec -T app node --input-type=module -e 'import { DatabaseSync, backup } from "node:sqlite"; await backup(new DatabaseSync(process.env.DATABASE_PATH), "/data/backup.sqlite");'
docker compose cp app:/data/backup.sqlite "$backup"
chmod 600 "$backup"
printf 'Backup saved: %s\n' "$backup"
