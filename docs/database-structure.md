# Database Schema (v3)

## `config`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `key` | TEXT | PK | Setting key |
| `value` | TEXT | | Setting value |

`version` key: schema version int. Table didn't exist pre-v2, so version ≥ 2 always.

## `frame`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK, AUTOINCREMENT | |
| `createdAt` | REAL | | Unix timestamp |
| `imgFilename` | TEXT | | Image filename |
| `segmentID` | INTEGER | NULL, FK `segments.id` | |
| `videoPath` | TEXT | NULL | Relative path, once encoded |
| `videoFrameIndex` | INTEGER | NULL | Index within encoded video |
| `collectionID` | INTEGER | NULL | |
| `encodeStatus` | INTEGER | DEFAULT 0 | 0=unencoded, 1=queued (in `encoding_task`), 2=encoded |

## `recognition_data`

OCR output per frame.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK, AUTOINCREMENT | |
| `frameID` | INTEGER | FK `frame.id` | |
| `data` | TEXT | | Raw OCR data |
| `text` | TEXT | | Recognized text |

## `segments`

A period of continuous use of one app — starts when the active window changes.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK, AUTOINCREMENT | |
| `startedAt` | REAL | | Unix timestamp |
| `endedAt` | REAL | | Unix timestamp |
| `title` | TEXT | | |
| `appName` | TEXT | | |
| `appPath` | TEXT | | |
| `text` | TEXT | | |
| `type` | TEXT | | |
| `appBundleID` | TEXT | NULL | |
| `url` | TEXT | NULL | |

## `encoding_task`

Queued FFmpeg encoding jobs.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK, AUTOINCREMENT | |
| `createdAt` | REAL | | Unix timestamp |
| `status` | INTEGER | DEFAULT 0 | 0=pending, 1=in progress, 2=completed → deleted by trigger below |

## `encoding_task_data`

Frame↔task join for pending encodes.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `encodingTaskID` | INTEGER | FK `encoding_task.id` | |
| `frame` | INTEGER | PK, FK `frame.id` | |

## `text_search` (virtual, FTS5)

Full-text index over `recognition_data`, kept in sync via triggers below.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | UNINDEXED | |
| `frameID` | INTEGER | UNINDEXED | |
| `data` | TEXT | | |
| `text` | TEXT | | |

## Triggers

`recognition_data_after_{insert,update,delete}` — mirror `recognition_data` rows into `text_search`:

```sql
CREATE TRIGGER IF NOT EXISTS recognition_data_after_insert AFTER INSERT ON recognition_data
BEGIN
    INSERT INTO text_search (id, frameID, data, text)
    VALUES (NEW.id, NEW.frameID, NEW.data, NEW.text);
END;

CREATE TRIGGER IF NOT EXISTS recognition_data_after_update AFTER UPDATE ON recognition_data
BEGIN
    UPDATE text_search
    SET frameID = NEW.frameID, data = NEW.data, text = NEW.text
    WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS recognition_data_after_delete AFTER DELETE ON recognition_data
BEGIN
    DELETE FROM text_search WHERE id = OLD.id;
END;
```

`delete_encoding_task` — on `encoding_task.status`→2, cascades delete to `encoding_task_data` + `encoding_task`:

```sql
CREATE TRIGGER IF NOT EXISTS delete_encoding_task
AFTER UPDATE OF status ON encoding_task
BEGIN
  DELETE FROM encoding_task_data WHERE encodingTaskID = OLD.id AND NEW.status = 2;
  DELETE FROM encoding_task WHERE id = OLD.id AND NEW.status = 2;
END;
```
