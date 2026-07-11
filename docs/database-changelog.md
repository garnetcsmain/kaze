# Database Schema Changelog

## v3 (since 0.5.0)

Renamed + converted to Unix timestamp: `encoding_task.createAt`→`createdAt`, `frame.createAt`→`createdAt`, `segments.{startAt,endAt}`→`{startedAt,endedAt}`. Dropped deprecated `frame.encoded`.

```sql
ALTER TABLE encoding_task RENAME COLUMN createAt TO createdAt;
ALTER TABLE frame RENAME COLUMN createAt TO createdAt;
ALTER TABLE segments RENAME COLUMN startAt TO startedAt;
ALTER TABLE segments RENAME COLUMN endAt TO endedAt;
ALTER TABLE frame DROP COLUMN encoded;
```

Conversion pattern (applied per renamed column above, via `convertTimestampToUnix()`):

```typescript
const rows = db.prepare(`SELECT id, createdAt FROM encoding_task`).all() as {
	[x: string]: unknown;
	id: unknown;
}[];
const updateStmt = db.prepare(`UPDATE encoding_task SET createdAt_new = ? WHERE id = ?`);
rows.forEach((row) => updateStmt.run(convertTimestampToUnix(row.createdAt as string), row.id));
```

## v2 (0.4.0)

New tables: `config` (key/value settings), `encoding_task` (queued jobs — `id`, `createAt`, `status`: 0=pending/1=in-progress/2=completed), `encoding_task_data` (frame↔task join). Current definitions in [database-structure.md](database-structure.md); `encoding_task.createAt` later renamed (v3, above).

`INSERT INTO config (key, value) VALUES ('version', '2');`

Trigger `delete_encoding_task` — on `status`→2, cascades delete to `encoding_task_data`+`encoding_task` (def. in database-structure.md).

`frame` changes:
- `imgFilename`: full path → bare filename
- Added `encodeStatus` INT, replacing deprecated `encoded` (kept as dead column — SQLite can't cheaply drop+recopy)

```sql
ALTER TABLE frame ADD encodeStatus INT;
UPDATE frame SET encodeStatus = CASE WHEN encoded THEN 2 ELSE 0 END;
```

## v1 (0.3.x) — initial schema

Baseline: `frame`, `recognition_data`, `segments`, `text_search` + sync triggers `recognition_data_after_{insert,update,delete}`. `recognition_data`, `text_search`, and the triggers are unchanged since — see [database-structure.md](database-structure.md).

`frame`/`segments` originally used string-timestamp columns, later renamed+converted to Unix time (v3): `frame.createAt`→`createdAt`, `segments.{startAt,endAt}`→`{startedAt,endedAt}`. `frame` also had boolean `encoded`, replaced by `encodeStatus` int (v2) but retained as dead column.
