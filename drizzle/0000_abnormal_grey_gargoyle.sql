CREATE TABLE `profiles` (
	`id` text PRIMARY KEY NOT NULL,
	`edit_hash` text NOT NULL,
	`download_hash` text NOT NULL,
	`profile_json` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
