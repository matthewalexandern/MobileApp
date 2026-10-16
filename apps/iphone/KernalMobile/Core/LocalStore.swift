import CryptoKit
import Foundation
import SQLite3

public enum LocalStoreError: Error, LocalizedError, Sendable, Equatable {
    case storageUnavailable, invalidRequest, quotaExceeded, conflict, notFound, cancelled
    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Protected local storage is unavailable. Unlock the iPhone and try again."
        case .invalidRequest: return "The local request is invalid or too large."
        case .quotaExceeded: return "Local storage has reached its limit. Create space before continuing."
        case .conflict: return "This request identifier was already used for different input."
        case .notFound: return "The local conversation or memory could not be found."
        case .cancelled: return "The local operation was cancelled."
        }
    }
}

/// One iPhone owner's local state. There is no network transport or remote
/// identity here. All SQL input is bound, and model output never creates facts.
public actor LocalStore {
    private let database: LocalSQLite
    public let directory: URL

    public init(directory: URL? = nil) throws {
        let manager = FileManager.default
        let requested: URL
        if let directory { requested = directory }
        else {
            requested = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("KernalOffline", isDirectory: true)
        }
        guard requested.isFileURL else { throw LocalStoreError.invalidRequest }
        let suppliedRoot = requested.standardizedFileURL
        // The app chooses this path. Refuse symlink substitution rather than
        // redirecting an existing database into a different storage location.
        if let attributes = try? manager.attributesOfItem(atPath: suppliedRoot.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw LocalStoreError.storageUnavailable
        }
        // iOS may represent its own container under /var -> /private/var.
        // Canonicalize the trusted parent, while never following the final root.
        let root = suppliedRoot.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(suppliedRoot.lastPathComponent, isDirectory: true).standardizedFileURL
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            try manager.setAttributes([.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
            var protectedRoot = root
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try protectedRoot.setResourceValues(resources)
            let file = root.appendingPathComponent("memory.sqlite3")
            if let attributes = try? manager.attributesOfItem(atPath: file.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      file.resolvingSymlinksInPath() == file else { throw LocalStoreError.storageUnavailable }
            } else {
                guard manager.createFile(atPath: file.path, contents: nil,
                    attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
                    throw LocalStoreError.storageUnavailable
                }
            }
            try manager.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            self.directory = root
            self.database = try LocalSQLite(path: file.path)
        } catch let error as LocalStoreError { throw error }
        catch { throw LocalStoreError.storageUnavailable }
    }

    public func close() { database.close() }

    public func listSessions() throws -> [ChatSession] {
        try checkCancellation()
        return try database.rows("SELECT id,title,created_at FROM sessions ORDER BY created_at,id").map(session)
    }

    public func createSession(title: String) throws -> ChatSession {
        try checkCancellation()
        guard validText(title, maximum: 256), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalStoreError.invalidRequest
        }
        guard try database.integer("SELECT count(*) FROM sessions") < 100 else { throw LocalStoreError.quotaExceeded }
        let value = ChatSession(id: UUID().uuidString, title: title, createdAt: Date())
        try database.execute("INSERT INTO sessions(id,title,created_at) VALUES(?,?,?)",
            [.text(value.id), .text(value.title), .number(value.createdAt.timeIntervalSince1970)])
        return value
    }

    public func messages(sessionID: String) throws -> [ChatMessage] {
        try checkCancellation(); try requireSession(sessionID)
        return try database.rows("SELECT id,role,text,created_at FROM messages WHERE session_id=? ORDER BY sequence",
            [.text(sessionID)]).map(message)
    }

    public func lookupTurn(sessionID: String, requestID: String, text: String, memoryEnabled: Bool) throws -> ChatTurn? {
        try checkCancellation(); try requireSession(sessionID)
        let fingerprint = try inputFingerprint(sessionID: sessionID, requestID: requestID, text: text, memoryEnabled: memoryEnabled)
        return try existingTurn(requestID: requestID, fingerprint: fingerprint)
    }

    /// The caller supplies a completed local inference result. User message,
    /// assistant reply and eligible preference updates commit in one transaction.
    /// A replay with the same request input returns the original committed reply.
    public func commitTurn(sessionID: String, requestID: String, text: String, assistantText: String, memoryEnabled: Bool) throws -> ChatTurn {
        try checkCancellation(); try requireSession(sessionID)
        let fingerprint = try inputFingerprint(sessionID: sessionID, requestID: requestID, text: text, memoryEnabled: memoryEnabled)
        if let prior = try existingTurn(requestID: requestID, fingerprint: fingerprint) { return prior }
        guard validText(assistantText, maximum: 512 * 1024), !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalStoreError.invalidRequest
        }
        guard try database.integer("SELECT count(*) FROM messages WHERE session_id=?", [.text(sessionID)]) <= 998,
              try database.integer("SELECT count(*) FROM messages") <= 9998 else { throw LocalStoreError.quotaExceeded }
        let now = Date()
        let user = ChatMessage(id: UUID().uuidString, role: "user", text: text, createdAt: now)
        let assistant = ChatMessage(id: UUID().uuidString, role: "assistant", text: assistantText, createdAt: now)
        let status = memoryEnabled ? "complete" : "disabled"
        try database.transaction {
            try checkCancellation()
            try database.execute("INSERT INTO turns(request_id,session_id,input_fingerprint,user_id,assistant_id,memory_status) VALUES(?,?,?,?,?,?)",
                [.text(requestID), .text(sessionID), .text(fingerprint), .text(user.id), .text(assistant.id), .text(status)])
            for value in [user, assistant] {
                try database.execute("INSERT INTO messages(id,session_id,request_id,role,text,created_at) VALUES(?,?,?,?,?,?)",
                    [.text(value.id), .text(sessionID), .text(requestID), .text(value.role), .text(value.text), .number(value.createdAt.timeIntervalSince1970)])
            }
            if memoryEnabled, let preference = Preference.fromUserText(text) {
                try remember(preference, sourceID: user.id, updated: now)
            }
            try checkCancellation()
        }
        return ChatTurn(user: user, assistant: assistant, memoryStatus: status)
    }

    public func searchMemory(query: String) throws -> [MemoryItem] {
        try checkCancellation()
        guard validText(query, maximum: 512, allowEmpty: true) else { throw LocalStoreError.invalidRequest }
        let terms = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard terms.count <= 64 else { throw LocalStoreError.invalidRequest }
        if terms.isEmpty {
            return try database.rows("SELECT id,kind,title,body,updated_at FROM memories ORDER BY updated_at DESC,id LIMIT 50").map(memory)
        }
        // FTS syntax is generated from literal words; operators, wildcards and
        // user-supplied SQL/FTS instructions never become executable syntax.
        let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        return try database.rows("SELECT m.id,m.kind,m.title,m.body,m.updated_at FROM memory_fts JOIN memories m ON m.id=memory_fts.memory_id WHERE memory_fts MATCH ? ORDER BY rank,m.id LIMIT 50",
            [.text(expression)]).map(memory)
    }

    public func forgetMemory(memoryID: String) throws {
        try checkCancellation()
        let rows = try database.rows("SELECT preference_key FROM memories WHERE id=?", [.text(memoryID)])
        guard let first = rows.first else { throw LocalStoreError.notFound }
        let key = first[0].string
        try database.transaction {
            try checkCancellation()
            try database.execute("INSERT OR IGNORE INTO memory_tombstones(preference_key,forgotten_at) VALUES(?,?)",
                [.text(key), .number(Date().timeIntervalSince1970)])
            try database.execute("DELETE FROM memory_fts WHERE memory_id=?", [.text(memoryID)])
            try database.execute("DELETE FROM memories WHERE id=?", [.text(memoryID)])
            try checkCancellation()
        }
    }

    private func requireSession(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw LocalStoreError.invalidRequest }
        guard try database.integer("SELECT count(*) FROM sessions WHERE id=?", [.text(id)]) == 1 else { throw LocalStoreError.notFound }
    }
    private func inputFingerprint(sessionID: String, requestID: String, text: String, memoryEnabled: Bool) throws -> String {
        guard UUID(uuidString: requestID) != nil, validText(text, maximum: 512 * 1024),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalStoreError.invalidRequest }
        struct Input: Encodable { let session: String; let request: String; let text: String; let memory: Bool }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Input(session: sessionID, request: requestID, text: text, memory: memoryEnabled))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func existingTurn(requestID: String, fingerprint: String) throws -> ChatTurn? {
        let rows = try database.rows("SELECT input_fingerprint,user_id,assistant_id,memory_status FROM turns WHERE request_id=?", [.text(requestID)])
        guard let first = rows.first else { return nil }
        guard first[0].string == fingerprint else { throw LocalStoreError.conflict }
        let userRows = try database.rows("SELECT id,role,text,created_at FROM messages WHERE id=?", [.text(first[1].string)])
        let assistantRows = try database.rows("SELECT id,role,text,created_at FROM messages WHERE id=?", [.text(first[2].string)])
        guard let user = userRows.first, let assistant = assistantRows.first else { throw LocalStoreError.storageUnavailable }
        return ChatTurn(user: message(user), assistant: message(assistant), memoryStatus: first[3].string)
    }
    private func remember(_ preference: Preference, sourceID: String, updated: Date) throws {
        guard try database.integer("SELECT count(*) FROM memory_tombstones WHERE preference_key=?", [.text(preference.key)]) == 0 else { return }
        let id = "chat:preference:" + preference.key
        try database.execute("DELETE FROM memory_fts WHERE memory_id=?", [.text(id)])
        try database.execute("INSERT INTO memories(id,preference_key,kind,title,body,source_message_id,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(preference_key) DO UPDATE SET title=excluded.title,body=excluded.body,source_message_id=excluded.source_message_id,updated_at=excluded.updated_at",
            [.text(id), .text(preference.key), .text("semantic"), .text(preference.title), .text(preference.body), .text(sourceID), .number(updated.timeIntervalSince1970)])
        try database.execute("INSERT INTO memory_fts(memory_id,title,body) VALUES(?,?,?)", [.text(id), .text(preference.title), .text(preference.body)])
    }
    private func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= maximum && !value.contains("\0")
    }
    private func checkCancellation() throws {
        guard !Task.isCancelled else { throw LocalStoreError.cancelled }
    }
    private func session(_ row: [SQLValue]) -> ChatSession { ChatSession(id: row[0].string, title: row[1].string, createdAt: Date(timeIntervalSince1970: row[2].number)) }
    private func message(_ row: [SQLValue]) -> ChatMessage { ChatMessage(id: row[0].string, role: row[1].string, text: row[2].string, createdAt: Date(timeIntervalSince1970: row[3].number)) }
    private func memory(_ row: [SQLValue]) -> MemoryItem {
        MemoryItem(id: row[0].string, kind: row[1].string, title: row[2].string, body: row[3].string,
            origin: "private", sourceURL: "", updatedAt: Date(timeIntervalSince1970: row[4].number), canForget: true)
    }
}

/// Small, deterministic allowlist. A paragraph, quoted document, web capture or
/// assistant instruction cannot match. The saved body is generated from known
/// values; it never copies an arbitrary instruction into future context.
private struct Preference {
    let key: String; let title: String; let body: String
    static func fromUserText(_ input: String) -> Preference? {
        guard input.utf8.count <= 256, !input.contains("\n"), !input.contains("\r") else { return nil }
        var sentence = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Actually, ", "Correction: ", "Remember that "] {
            if sentence.lowercased().hasPrefix(prefix.lowercased()) { sentence.removeFirst(prefix.count); break }
        }
        if sentence.hasSuffix(".") { sentence.removeLast() }
        let normalized = sentence.lowercased()
        for language in ["Go", "Python", "Swift", "Rust", "TypeScript", "JavaScript", "C", "C++", "Java", "Kotlin"] {
            for target in ["server projects", "server tools", "backend development"] {
                if normalized == "i prefer \(language.lowercased()) for \(target)" {
                    return Preference(key: "server-language", title: "Server language preference", body: "I prefer \(language) for server projects.")
                }
            }
        }
        for style in ["concise", "detailed"] {
            if normalized == "i prefer \(style) answers" {
                return Preference(key: "answer-style", title: "Answer style preference", body: "I prefer \(style) answers.")
            }
        }
        return nil
    }
}

private enum SQLValue {
    case text(String), number(Double), integer(Int64), null
    var string: String { if case let .text(value) = self { return value }; return "" }
    var number: Double {
        switch self { case let .number(value): return value; case let .integer(value): return Double(value); default: return 0 }
    }
}

private final class LocalSQLite {
    private var handle: OpaquePointer?
    // Exported as a literal so the exact schema can also be validated by SQLite
    // tooling outside Xcode. No triggers need trusted_schema or executable SQL.
    static let schema = """
    CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,title TEXT NOT NULL,created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS turns(request_id TEXT PRIMARY KEY,session_id TEXT NOT NULL REFERENCES sessions(id),input_fingerprint TEXT NOT NULL,user_id TEXT NOT NULL,assistant_id TEXT NOT NULL,memory_status TEXT NOT NULL CHECK(memory_status IN ('complete','disabled')));
    CREATE TABLE IF NOT EXISTS messages(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,session_id TEXT NOT NULL REFERENCES sessions(id),request_id TEXT NOT NULL REFERENCES turns(request_id),role TEXT NOT NULL CHECK(role IN ('user','assistant')),text TEXT NOT NULL,created_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id,sequence);
    CREATE TABLE IF NOT EXISTS memories(id TEXT PRIMARY KEY,preference_key TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,source_message_id TEXT NOT NULL REFERENCES messages(id),updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS memory_tombstones(preference_key TEXT PRIMARY KEY,forgotten_at REAL NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(memory_id UNINDEXED,title,body,tokenize='unicode61 remove_diacritics 2');
    PRAGMA user_version=1;
    """

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close_v2(handle) }; handle = nil
            throw LocalStoreError.storageUnavailable
        }
        do {
            sqlite3_busy_timeout(handle, 1000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA page_size=4096")
            guard try integer("PRAGMA page_size") == 4096,
                  try integer("PRAGMA page_count") <= 131072 else { throw LocalStoreError.storageUnavailable }
            try execute("PRAGMA max_page_count=131072")
            let version = try integer("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw LocalStoreError.storageUnavailable }
            guard let handle, sqlite3_exec(handle, Self.schema, nil, nil, nil) == SQLITE_OK else { throw LocalStoreError.storageUnavailable }
            guard try rows("PRAGMA quick_check(1)").first?.first?.string == "ok" else { throw LocalStoreError.storageUnavailable }
        } catch { close(); throw LocalStoreError.storageUnavailable }
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close_v2(handle) }; handle = nil }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        guard let value = try rows(sql, values).first?.first else { throw LocalStoreError.storageUnavailable }
        return Int64(value.number)
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        guard let handle else { throw LocalStoreError.storageUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LocalStoreError.storageUnavailable }
        defer { sqlite3_finalize(statement) }
        guard Int(sqlite3_bind_parameter_count(statement)) == values.count else { throw LocalStoreError.storageUnavailable }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case let .number(number): result = sqlite3_bind_double(statement, index, number)
            case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw LocalStoreError.storageUnavailable }
        }
        var result: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            if status == SQLITE_FULL { throw LocalStoreError.quotaExceeded }
            guard status == SQLITE_ROW else { throw LocalStoreError.storageUnavailable }
            var row: [SQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.number(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement, column) else { throw LocalStoreError.storageUnavailable }
                    row.append(.text(String(cString: pointer)))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
    }
}
