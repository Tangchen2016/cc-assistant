import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

export const profiles = sqliteTable("profiles", {
  id: text("id").primaryKey(),
  editHash: text("edit_hash").notNull(),
  downloadHash: text("download_hash").notNull(),
  profileJson: text("profile_json").notNull(),
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
});

export const remoteCaches = sqliteTable("remote_caches", {
  id: text("id").primaryKey(),
  editHash: text("edit_hash").notNull(),
  downloadHash: text("download_hash").notNull(),
  profileJson: text("profile_json").notNull(),
  sourceYaml: text("source_yaml").notNull(),
  sourceFetchedAt: text("source_fetched_at").notNull(),
  userInfo: text("user_info"),
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
});
