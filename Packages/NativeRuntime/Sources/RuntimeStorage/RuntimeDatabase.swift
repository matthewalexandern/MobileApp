import CSQLite
import Foundation

/// Values are always bound separately from SQL. Database errors never include SQL or record contents.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public typealias SQLiteRow = [String: SQLiteValue]

public enum StorageError: Error, Sendable, Equatable {
    case openFailed(code: Int32)
    case databaseFailure(operation: String, code: Int32)
    case invalidMigrationSequence
    case unsupportedSchemaVersion(Int)
    case migrationFailed(version: Int, code: Int32)
    case invalidParameterCount(expected: Int, actual: Int)
    case valueTooLarge
    case invalidAppDirectoryName
    case fileProtectionFailed
}

public struct SQLiteMigration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let statements: [String]

    public init(version: Int, name: String, statements: [String]) {
        self.version = version
        self.name = name
        self.statements = statements
    }
}

/// Serializes access to one SQLite connection. Use a protected app-container URL on iOS.
/// This skeleton stores plaintext; apply iOS file protection before storing sensitive records.
public actor RuntimeDatabase {
    private let connection: SQLiteConnection

    /// Raw paths support tests and migration tooling. Production iOS callers should use
    /// `init(protectedAppDirectoryName:migrations:)` to protect SQLite and its sidecar files.
    public init(path: String = ":memory:", migrations: [SQLiteMigration] = RuntimeSchema.migrations) throws {
        let connection = try SQLiteConnection(path: path)
        try connection.apply(migrations)
        self.connection = connection
    }

    #if os(iOS)
    /// Creates a dedicated Application Support directory with complete file protection.
    /// SQLite access can fail while the device is locked; M0 supports foreground use only.
    public init(protectedAppDirectoryName: String, migrations: [SQLiteMigration] = RuntimeSchema.migrations) throws {
        let path = try Self.protectedDatabasePath(directoryName: protectedAppDirectoryName)
        let connection = try SQLiteConnection(path: path)
        try connection.apply(migrations)
        self.connection = connection
    }

    private static func protectedDatabasePath(directoryName: String) throws -> String {
        guard !directoryName.isEmpty, directoryName != ".", directoryName != "..",
              !directoryName.contains("/"), !directoryName.contains("\\"), !directoryName.contains("\0") else {
            throw StorageError.invalidAppDirectoryName
        }
        do {
            let manager = FileManager.default
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var directory = support.appendingPathComponent(directoryName, isDirectory: true)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
            // createDirectory does not update an already existing directory's attributes.
            try manager.setAttributes(attributes, ofItemAtPath: directory.path)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try directory.setResourceValues(resourceValues)
            let database = directory.appendingPathComponent("runtime.sqlite")
            // Protect existing SQLite sidecars before opening. New sidecars inherit the
            // dedicated directory's protection class; verify this on a physical device.
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let path = database.path + suffix
                if manager.fileExists(atPath: path) { try manager.setAttributes(attributes, ofItemAtPath: path) }
            }
            return database.path
        } catch {
            throw StorageError.fileProtectionFailed
        }
    }
    #endif

    public func schemaVersion() throws -> Int {
        try connection.schemaVersion()
    }

    public func execute(_ sql: String, parameters: [SQLiteValue] = []) throws {
        _ = try connection.run(sql, parameters: parameters)
    }

    public func query(_ sql: String, parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try connection.run(sql, parameters: parameters)
    }

    /// All statements succeed together or the connection rolls them back.
    public func transaction(_ statements: [(sql: String, parameters: [SQLiteValue])]) throws {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            for statement in statements {
                _ = try connection.run(statement.sql, parameters: statement.parameters)
            }
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }
}

// The actor is the sole owner after initialization. FULLMUTEX also protects SQLite itself.
// This wrapper keeps the native pointer out of a Swift actor's nonisolated deinitializer.
private final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer

    init(path: String) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw StorageError.openFailed(code: code)
        }
        handle = pointer
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)
        try executeScript("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    func schemaVersion() throws -> Int {
        let rows = try run("PRAGMA user_version", parameters: [])
        guard case .integer(let version) = rows.first?["user_version"] else {
            throw StorageError.databaseFailure(operation: "read schema version", code: SQLITE_ERROR)
        }
        return Int(version)
    }

    func apply(_ migrations: [SQLiteMigration]) throws {
        guard migrations.enumerated().allSatisfy({ $0.element.version == $0.offset + 1 }) else {
            throw StorageError.invalidMigrationSequence
        }
        let current = try schemaVersion()
        guard current <= migrations.count else { throw StorageError.unsupportedSchemaVersion(current) }
        let pending = migrations.filter { $0.version > current }
        guard !pending.isEmpty else { return }

        try executeScript("BEGIN IMMEDIATE")
        var applyingVersion = pending[0].version
        do {
            for migration in pending {
                applyingVersion = migration.version
                for statement in migration.statements { try executeScript(statement) }
                // Version is validated above and cannot contain untrusted SQL.
                try executeScript("PRAGMA user_version = \(migration.version)")
            }
            try executeScript("COMMIT")
        } catch {
            let code = sqlite3_extended_errcode(handle)
            try? executeScript("ROLLBACK")
            throw StorageError.migrationFailed(version: applyingVersion, code: code)
        }
    }

    func executeScript(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw StorageError.databaseFailure(operation: "execute schema statement", code: code)
        }
    }

    func run(_ sql: String, parameters: [SQLiteValue]) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw StorageError.databaseFailure(operation: "prepare statement", code: prepareCode)
        }
        defer { sqlite3_finalize(statement) }

        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw StorageError.invalidParameterCount(expected: expected, actual: parameters.count)
        }
        for (offset, value) in parameters.enumerated() {
            try bind(value, at: Int32(offset + 1), to: statement)
        }

        var rows: [SQLiteRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else {
                throw StorageError.databaseFailure(operation: "step statement", code: code)
            }
            var row: SQLiteRow = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_text(statement, column) {
                        row[name] = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
                    } else { row[name] = .text("") }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else { row[name] = .blob(Data()) }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
    }

    private func bind(_ value: SQLiteValue, at index: Int32, to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code: Int32
        switch value {
        case .null: code = sqlite3_bind_null(statement, index)
        case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
        case .real(let number): code = sqlite3_bind_double(statement, index, number)
        case .text(let text):
            let bytes = text.utf8.count
            guard bytes <= Int(Int32.max) else { throw StorageError.valueTooLarge }
            code = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(bytes), transient) }
        case .blob(let data):
            guard data.count <= Int(Int32.max) else { throw StorageError.valueTooLarge }
            if data.isEmpty {
                code = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
        }
        guard code == SQLITE_OK else {
            throw StorageError.databaseFailure(operation: "bind parameter", code: code)
        }
    }
}
