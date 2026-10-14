CREATE TABLE `remote_caches` (
	`id` text PRIMARY KEY NOT NULL,
	`edit_hash` text NOT NULL,
	`download_hash` text NOT NULL,
	`profile_json` text NOT NULL,
	`source_yaml` text NOT NULL,
	`source_fetched_at` text NOT NULL,
	`user_info` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
