# ADR 0003: SQLite and read-only intelligence foundations

Status: Accepted for M0.

Use the system SQLite library with ordered transactional migrations and FTS5.
Keep a schema for conversations, sources, preferences, inventory, vulnerability
records, patch status, and audit events. M0 creates and tests the schema; it does
not claim production persistence, semantic memory, or inventory correlation.

SQLite avoids a new persistence dependency. FTS5 availability must be checked
at migration time and failure surfaced rather than creating a partially migrated
database. Future migrations must preserve existing data and run transactionally.
The iOS `RuntimeDatabase(protectedAppDirectoryName:)` initializer applies
`NSFileProtectionComplete` to its Application Support directory and existing
database/sidecars before opening SQLite, and excludes the directory from backup.
Locked-device access can fail; physical-device checks must verify protection
inheritance for newly created journal/WAL files. The raw-path initializer is for
tests and developer tooling. M0 does not wire durable chat into the application.
Protection is not equivalent to a separately encrypted SQLite engine: unlocked devices and
backups have their own risk. Keychain secret storage is deferred until a feature
actually needs credentials.

Normalize CISA KEV data offline, with strict identity validation, deduplication,
source timestamps, and authoritative links. Model text and feed descriptions
remain data and cannot invoke tools. The Vulnerabilities tab does not claim that
a CVE applies to an asset without normalized product/version evidence. Live CISA
and NVD fetching, pagination, retries, cached-feed UI, and matching are M3 work.
