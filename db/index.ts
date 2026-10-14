import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { mkdirSync, chmodSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { drizzle } from "drizzle-orm/sqlite-proxy";
import * as schema from "./schema.ts";

let instance: ReturnType<typeof openDatabase> | undefined;
function openDatabase() {
  const path = resolve(process.env.DATABASE_PATH ?? "data/cc-assistant.sqlite");
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const sqlite = new DatabaseSync(path);
  chmodSync(path, 0o600);
  sqlite.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS profiles (id TEXT PRIMARY KEY, edit_hash TEXT NOT NULL, download_hash TEXT NOT NULL, profile_json TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS remote_caches (id TEXT PRIMARY KEY, edit_hash TEXT NOT NULL, download_hash TEXT NOT NULL, profile_json TEXT NOT NULL, source_yaml TEXT NOT NULL, source_fetched_at TEXT NOT NULL, user_info TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS source_caches (id TEXT PRIMARY KEY, source_url_hash TEXT NOT NULL, source_yaml TEXT NOT NULL, fetched_at TEXT NOT NULL, user_info TEXT);`);
  const db = drizzle(async (sql, params, method) => {
    const statement = sqlite.prepare(sql);
    const values = params as SQLInputValue[];
    if (method === "run") { statement.run(...values); return { rows: [] }; }
    const rows = statement.all(...values).map(row => Object.values(row));
    return { rows: method === "get" ? rows[0] ?? [] : rows };
  }, { schema });
  return { sqlite, db };
}
export function getDb() { return (instance ??= openDatabase()).db; }
export function getSqlite() { return (instance ??= openDatabase()).sqlite; }
