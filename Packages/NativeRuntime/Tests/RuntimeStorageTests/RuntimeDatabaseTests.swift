import Foundation
import RuntimeStorage
import Testing

@Test func appliesSchemaAndPreservesRecordsWhenReopened() async throws {
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let first = try RuntimeDatabase(path: path)
    #expect(try await first.schemaVersion() == 2)
    try await first.execute(
        "INSERT INTO preferences(key, value, updated_at) VALUES (?, ?, ?)",
        parameters: [.text("context"), .text("2048"), .text("2026-10-08T00:00:00Z")]
    )

    let reopened = try RuntimeDatabase(path: path)
    #expect(try await reopened.schemaVersion() == 2)
    #expect(try await reopened.query("SELECT value FROM preferences WHERE key = ?", parameters: [.text("context")]) == [
        ["value": .text("2048")]
    ])
    let tables = try await reopened.query("SELECT name FROM sqlite_master WHERE type = 'table'")
    for name in ["conversations", "messages", "sources", "preferences", "inventory", "cves", "patch_status", "audit"] {
        #expect(tables.contains(["name": .text(name)]))
    }
}

@Test func failedMigrationRollsBackEntirePendingBatch() async throws {
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let migrations = [
        SQLiteMigration(version: 1, name: "create temporary table", statements: ["CREATE TABLE partial(id INTEGER)"]),
        SQLiteMigration(version: 2, name: "invalid SQL", statements: ["THIS IS NOT SQL"])
    ]
    do {
        _ = try RuntimeDatabase(path: path, migrations: migrations)
        Issue.record("Invalid migration should fail")
    } catch let error as StorageError {
        guard case .migrationFailed(version: 2, code: _) = error else {
            Issue.record("Expected structured migration failure")
            return
        }
    }
    let clean = try RuntimeDatabase(path: path, migrations: [])
    #expect(try await clean.schemaVersion() == 0)
    #expect(try await clean.query("SELECT name FROM sqlite_master WHERE name = 'partial'").isEmpty)
}

@Test func rejectsMigrationGapsAndSchemaDowngrades() async throws {
    #expect(throws: StorageError.invalidMigrationSequence) {
        try RuntimeDatabase(migrations: [SQLiteMigration(version: 2, name: "gap", statements: [])])
    }
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = try RuntimeDatabase(path: path)
    #expect(try await database.schemaVersion() == 2)
    #expect(throws: StorageError.unsupportedSchemaVersion(2)) {
        try RuntimeDatabase(path: path, migrations: Array(RuntimeSchema.migrations.prefix(1)))
    }
}

@Test func ftsTracksUpdatesAndConversationCascadeDeletion() async throws {
    let database = try RuntimeDatabase()
    try await database.execute(
        "INSERT INTO conversations(id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
        parameters: [.text("chat"), .text("Security review"), .text("now"), .text("now")]
    )
    try await database.execute(
        "INSERT INTO messages(id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)",
        parameters: [.text("message"), .text("chat"), .text("user"), .text("Review my inventory"), .text("now")]
    )
    #expect(try await database.query("SELECT rowid FROM conversation_search WHERE conversation_search MATCH ?", parameters: [.text("security")]).count == 1)
    #expect(try await database.query("SELECT rowid FROM message_search WHERE message_search MATCH ?", parameters: [.text("inventory")]).count == 1)
    try await database.execute("UPDATE messages SET content = ? WHERE id = ?", parameters: [.text("Check updates"), .text("message")])
    #expect(try await database.query("SELECT rowid FROM message_search WHERE message_search MATCH ?", parameters: [.text("inventory")]).isEmpty)
    #expect(try await database.query("SELECT rowid FROM message_search WHERE message_search MATCH ?", parameters: [.text("updates")]).count == 1)
    try await database.execute("DELETE FROM conversations WHERE id = ?", parameters: [.text("chat")])
    #expect(try await database.query("SELECT id FROM messages").isEmpty)
    #expect(try await database.query("SELECT rowid FROM message_search WHERE message_search MATCH ?", parameters: [.text("updates")]).isEmpty)
    #expect(try await database.query("SELECT rowid FROM conversation_search WHERE conversation_search MATCH ?", parameters: [.text("security")]).isEmpty)
}

@Test func ftsRebuildIndexesRecordsWrittenBeforeSearchMigration() async throws {
    let path = temporaryDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let original = try RuntimeDatabase(path: path, migrations: Array(RuntimeSchema.migrations.prefix(1)))
    try await original.execute(
        "INSERT INTO sources(id, kind, title, body, fetched_at) VALUES (?, ?, ?, ?, ?)",
        parameters: [.text("source"), .text("cisa_kev"), .text("Catalog"), .text("Authoritative vulnerability information"), .text("now")]
    )
    let upgraded = try RuntimeDatabase(path: path)
    #expect(try await upgraded.query("SELECT rowid FROM source_search WHERE source_search MATCH ?", parameters: [.text("authoritative")]).count == 1)
    try await upgraded.execute("UPDATE sources SET body = ? WHERE id = ?", parameters: [.text("Updated offline catalog"), .text("source")])
    #expect(try await upgraded.query("SELECT rowid FROM source_search WHERE source_search MATCH ?", parameters: [.text("authoritative")]).isEmpty)
    #expect(try await upgraded.query("SELECT rowid FROM source_search WHERE source_search MATCH ?", parameters: [.text("offline")]).count == 1)
    try await upgraded.execute("DELETE FROM sources WHERE id = ?", parameters: [.text("source")])
    #expect(try await upgraded.query("SELECT rowid FROM source_search WHERE source_search MATCH ?", parameters: [.text("offline")]).isEmpty)
}

@Test func transactionsAndParameterBindingProtectRecordIntegrity() async throws {
    let database = try RuntimeDatabase()
    do {
        try await database.transaction([
            (sql: "INSERT INTO preferences(key, value, updated_at) VALUES (?, ?, ?)", parameters: [.text("pending"), .text("value"), .text("now")]),
            (sql: "INSERT INTO messages(id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)", parameters: [.text("orphan"), .text("missing"), .text("user"), .text("private content"), .text("now")])
        ])
        Issue.record("Foreign key violation should fail")
    } catch let error as StorageError {
        guard case .databaseFailure(operation: "step statement", code: _) = error else {
            Issue.record("Expected structured statement failure")
            return
        }
    }
    #expect(try await database.query("SELECT key FROM preferences").isEmpty)
    let untrustedText = "'); DROP TABLE preferences; --"
    try await database.execute("INSERT INTO preferences(key, value, updated_at) VALUES (?, ?, ?)", parameters: [.text("bound"), .text(untrustedText), .text("now")])
    #expect(try await database.query("SELECT value FROM preferences WHERE key = ?", parameters: [.text("bound")]) == [["value": .text(untrustedText)]])
    #expect(try await database.query("SELECT COUNT(*) AS count FROM preferences") == [["count": .integer(1)]])
}

@Test func bindsBinaryAndEmbeddedNullTextWithoutTruncation() async throws {
    let database = try RuntimeDatabase(migrations: [])
    try await database.execute("CREATE TABLE values_test(text_value TEXT, blob_value BLOB)")
    let text = "before\0after"
    let blob = Data([0, 1, 0, 255])
    try await database.execute("INSERT INTO values_test VALUES (?, ?)", parameters: [.text(text), .blob(blob)])
    #expect(try await database.query("SELECT text_value, blob_value FROM values_test") == [["text_value": .text(text), "blob_value": .blob(blob)]])
}

private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("native-runtime-\(UUID().uuidString).sqlite").path
}
