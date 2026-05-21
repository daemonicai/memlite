-- memlite schema. See openspec/changes/v1-foundation/specs/schema/spec.md
-- for the normative requirements behind each table and trigger.
--
-- The {DIM} placeholder is substituted at first-init time with the
-- embedding dimension discovered from the configured model.

BEGIN;

-- Core memory rows. Identity is the opaque integer PK so deletes never
-- recycle ids and history references stay unambiguous. slug is an
-- optional logical name; NULL slugs are allowed (and SQLite treats NULL
-- as distinct under UNIQUE).
CREATE TABLE memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT UNIQUE,
  format TEXT NOT NULL DEFAULT 'text'
    CHECK (format IN ('text', 'markdown')),
  content TEXT NOT NULL,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  last_accessed INTEGER NOT NULL
);

-- EAV tags. WITHOUT ROWID because (memory_id, key, value) IS the row.
-- ON DELETE CASCADE flows from memories so tag GC is automatic.
CREATE TABLE tags (
  memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (memory_id, key, value)
) WITHOUT ROWID;

CREATE INDEX tags_key_value ON tags(key, value);

-- Chunks are the unit of embedding and full-text indexing. id is the
-- rowid that vec_chunks and fts_chunks key off, so deletes here cascade
-- (via triggers) into both virtual tables.
CREATE TABLE chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  ord INTEGER NOT NULL,
  text TEXT NOT NULL,
  UNIQUE (memory_id, ord)
);

CREATE VIRTUAL TABLE fts_chunks USING fts5(
  text,
  content='chunks',
  content_rowid='id'
);

CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding FLOAT[{DIM}]);

-- Settings pin schema-affecting config (most importantly model_url and
-- embedding_dim — changing either silently would corrupt the vector index).
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;

-- History snapshots prior memory state on delete or content update.
-- Tag-only mutations are deliberately NOT snapshotted (per spec).
CREATE TABLE memories_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id INTEGER NOT NULL,
  slug TEXT,
  format TEXT NOT NULL,
  content TEXT NOT NULL,
  tags_snapshot TEXT NOT NULL,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  last_accessed INTEGER NOT NULL,
  archived_at INTEGER NOT NULL,
  archive_reason TEXT NOT NULL
    CHECK (archive_reason IN ('deleted', 'updated'))
);

CREATE INDEX memories_history_memory_id ON memories_history(memory_id);

-- FTS sync triggers (external-content FTS5 doesn't auto-mirror).
CREATE TRIGGER chunks_ai_fts AFTER INSERT ON chunks BEGIN
  INSERT INTO fts_chunks(rowid, text) VALUES (NEW.id, NEW.text);
END;

CREATE TRIGGER chunks_ad_fts AFTER DELETE ON chunks BEGIN
  DELETE FROM fts_chunks WHERE rowid = OLD.id;
END;

-- Vector cleanup follows the chunk row.
CREATE TRIGGER chunks_ad_vec AFTER DELETE ON chunks BEGIN
  DELETE FROM vec_chunks WHERE rowid = OLD.id;
END;

-- History on delete: snapshot before the row + its tags go.
CREATE TRIGGER memories_bd_history BEFORE DELETE ON memories BEGIN
  INSERT INTO memories_history (
    memory_id, slug, format, content,
    tags_snapshot, created, updated, last_accessed,
    archived_at, archive_reason
  ) VALUES (
    OLD.id, OLD.slug, OLD.format, OLD.content,
    IFNULL((
      SELECT json_group_object(key, json(vals)) FROM (
        SELECT key, json_group_array(value) AS vals
        FROM tags WHERE memory_id = OLD.id
        GROUP BY key
      )
    ), '{}'),
    OLD.created, OLD.updated, OLD.last_accessed,
    unixepoch(), 'deleted'
  );
END;

-- History on content update: only fires when content actually changes,
-- so slug-rename and tag-only updates don't pollute history.
CREATE TRIGGER memories_bu_content_history
BEFORE UPDATE OF content ON memories BEGIN
  INSERT INTO memories_history (
    memory_id, slug, format, content,
    tags_snapshot, created, updated, last_accessed,
    archived_at, archive_reason
  ) VALUES (
    OLD.id, OLD.slug, OLD.format, OLD.content,
    IFNULL((
      SELECT json_group_object(key, json(vals)) FROM (
        SELECT key, json_group_array(value) AS vals
        FROM tags WHERE memory_id = OLD.id
        GROUP BY key
      )
    ), '{}'),
    OLD.created, OLD.updated, OLD.last_accessed,
    unixepoch(), 'updated'
  );
END;

COMMIT;
