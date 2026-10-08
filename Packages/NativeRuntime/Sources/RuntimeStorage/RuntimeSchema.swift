/// M0 persistence foundation only: no retention policy, inventory correlation, or remote actions.
public enum RuntimeSchema {
    public static let migrations: [SQLiteMigration] = [
        SQLiteMigration(version: 1, name: "core records", statements: [
            """
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE messages (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant')),
                content TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE INDEX messages_conversation_time ON messages(conversation_id, created_at);
            CREATE TABLE sources (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                url TEXT,
                published_at TEXT,
                fetched_at TEXT NOT NULL
            );
            CREATE TABLE preferences (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE inventory (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                vendor TEXT,
                product TEXT,
                version TEXT,
                normalized_cpe TEXT,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE cves (
                id TEXT PRIMARY KEY NOT NULL,
                summary TEXT NOT NULL,
                source_id TEXT REFERENCES sources(id) ON DELETE SET NULL,
                kev INTEGER NOT NULL DEFAULT 0 CHECK(kev IN (0, 1)),
                cvss_score REAL CHECK(cvss_score BETWEEN 0 AND 10),
                published_at TEXT,
                source_updated_at TEXT,
                fetched_at TEXT NOT NULL,
                applicability TEXT NOT NULL DEFAULT 'unknown'
                    CHECK(applicability IN ('unknown', 'potential', 'confirmed', 'not_applicable'))
            );
            CREATE TABLE patch_status (
                cve_id TEXT NOT NULL REFERENCES cves(id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES inventory(id) ON DELETE CASCADE,
                status TEXT NOT NULL DEFAULT 'unknown'
                    CHECK(status IN ('unknown', 'not_available', 'available', 'applied')),
                last_reviewed_at TEXT,
                note TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(cve_id, asset_id)
            );
            CREATE TABLE audit (
                id TEXT PRIMARY KEY NOT NULL,
                action TEXT NOT NULL,
                decision TEXT NOT NULL CHECK(decision IN ('read_only', 'requested', 'approved', 'denied')),
                created_at TEXT NOT NULL,
                metadata_json TEXT NOT NULL DEFAULT '{}'
            );
            """
        ]),
        SQLiteMigration(version: 2, name: "full text search", statements: [
            """
            CREATE VIRTUAL TABLE conversation_search USING fts5(title, content='conversations', content_rowid='rowid');
            CREATE VIRTUAL TABLE message_search USING fts5(content, content='messages', content_rowid='rowid');
            CREATE VIRTUAL TABLE source_search USING fts5(title, body, content='sources', content_rowid='rowid');

            CREATE TRIGGER conversation_search_insert AFTER INSERT ON conversations BEGIN
                INSERT INTO conversation_search(rowid, title) VALUES (new.rowid, new.title);
            END;
            CREATE TRIGGER conversation_search_delete AFTER DELETE ON conversations BEGIN
                INSERT INTO conversation_search(conversation_search, rowid, title) VALUES ('delete', old.rowid, old.title);
            END;
            CREATE TRIGGER conversation_search_update AFTER UPDATE ON conversations BEGIN
                INSERT INTO conversation_search(conversation_search, rowid, title) VALUES ('delete', old.rowid, old.title);
                INSERT INTO conversation_search(rowid, title) VALUES (new.rowid, new.title);
            END;
            CREATE TRIGGER message_search_insert AFTER INSERT ON messages BEGIN
                INSERT INTO message_search(rowid, content) VALUES (new.rowid, new.content);
            END;
            CREATE TRIGGER message_search_delete AFTER DELETE ON messages BEGIN
                INSERT INTO message_search(message_search, rowid, content) VALUES ('delete', old.rowid, old.content);
            END;
            CREATE TRIGGER message_search_update AFTER UPDATE ON messages BEGIN
                INSERT INTO message_search(message_search, rowid, content) VALUES ('delete', old.rowid, old.content);
                INSERT INTO message_search(rowid, content) VALUES (new.rowid, new.content);
            END;
            CREATE TRIGGER source_search_insert AFTER INSERT ON sources BEGIN
                INSERT INTO source_search(rowid, title, body) VALUES (new.rowid, new.title, new.body);
            END;
            CREATE TRIGGER source_search_delete AFTER DELETE ON sources BEGIN
                INSERT INTO source_search(source_search, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
            END;
            CREATE TRIGGER source_search_update AFTER UPDATE ON sources BEGIN
                INSERT INTO source_search(source_search, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
                INSERT INTO source_search(rowid, title, body) VALUES (new.rowid, new.title, new.body);
            END;

            INSERT INTO conversation_search(conversation_search) VALUES ('rebuild');
            INSERT INTO message_search(message_search) VALUES ('rebuild');
            INSERT INTO source_search(source_search) VALUES ('rebuild');
            """
        ])
    ]
}
