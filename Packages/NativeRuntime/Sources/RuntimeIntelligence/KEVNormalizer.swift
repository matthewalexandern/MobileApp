import Foundation

public enum FeedNormalizationError: Error, Sendable, Equatable {
    case payloadTooLarge
    case invalidSchema
    case invalidField(String)
    case invalidCVEIdentifier(String)
    case invalidDate(field: String)
    case countMismatch(declared: Int, actual: Int)
    case duplicateConflict(String)
}

public enum VulnerabilityApplicability: String, Sendable, Codable {
    /// A feed entry alone cannot establish relevance to the user's environment.
    case unknown
}

public enum RansomwareCampaignUse: String, Sendable, Codable {
    case known = "Known"
    case unknown = "Unknown"
}

/// All feed-provided strings are untrusted display data, never executable instructions.
public struct NormalizedKEVVulnerability: Sendable, Equatable {
    public let cveID: String
    public let vendor: String
    public let product: String
    public let title: String
    public let summary: String
    public let informationalRequiredAction: String
    public let notes: String
    public let dateAdded: Date
    public let dueDate: Date
    public let ransomwareCampaignUse: RansomwareCampaignUse
    public let sourceUpdatedAt: Date
    public let fetchedAt: Date
    public let catalogURL: URL
    public let nvdURL: URL
    public let applicability: VulnerabilityApplicability

    public var isKnownExploited: Bool { true }
}

public struct NormalizedKEVCatalog: Sendable, Equatable {
    public let title: String
    public let version: String
    public let releasedAt: Date
    public let fetchedAt: Date
    public let vulnerabilities: [NormalizedKEVVulnerability]
}

/// Validates a caller-supplied CISA KEV JSON snapshot without fetching URLs or executing actions.
/// Schema drift and contradictory duplicates fail the entire snapshot; keep the previous cached copy.
public struct KEVNormalizer: Sendable {
    public static let maximumPayloadBytes = 16 * 1_024 * 1_024
    public static let maximumEntries = 20_000
    public static let catalogURL = URL(string: "https://www.cisa.gov/known-exploited-vulnerabilities-catalog")!

    public init() {}

    public func normalize(_ data: Data, fetchedAt: Date) throws -> NormalizedKEVCatalog {
        guard data.count <= Self.maximumPayloadBytes else { throw FeedNormalizationError.payloadTooLarge }
        let input: CatalogPayload
        do { input = try JSONDecoder().decode(CatalogPayload.self, from: data) }
        catch { throw FeedNormalizationError.invalidSchema }

        let title = try validatedText(input.title, field: "title", maximumLength: 1_024)
        let version = try validatedText(input.catalogVersion, field: "catalogVersion", maximumLength: 128)
        guard fetchedAt.timeIntervalSince1970.isFinite else {
            throw FeedNormalizationError.invalidDate(field: "fetchedAt")
        }
        let releasedAt = try timestamp(input.dateReleased, field: "dateReleased")
        guard input.vulnerabilities.count <= Self.maximumEntries, input.count >= 0 else {
            throw FeedNormalizationError.invalidField("count")
        }
        guard input.count == input.vulnerabilities.count else {
            throw FeedNormalizationError.countMismatch(declared: input.count, actual: input.vulnerabilities.count)
        }

        var byIdentifier: [String: NormalizedKEVVulnerability] = [:]
        for entry in input.vulnerabilities {
            let identifier = try normalizedCVEID(entry.cveID)
            let dateAdded = try calendarDate(entry.dateAdded, field: "dateAdded")
            let dueDate = try calendarDate(entry.dueDate, field: "dueDate")
            guard dueDate >= dateAdded, dateAdded <= releasedAt else {
                throw FeedNormalizationError.invalidDate(field: "entry chronology")
            }
            let vulnerability = NormalizedKEVVulnerability(
                cveID: identifier,
                vendor: try validatedText(entry.vendorProject, field: "vendorProject", maximumLength: 1_024),
                product: try validatedText(entry.product, field: "product", maximumLength: 1_024),
                title: try validatedText(entry.vulnerabilityName, field: "vulnerabilityName", maximumLength: 2_048),
                summary: try validatedText(entry.shortDescription, field: "shortDescription", maximumLength: 32_768),
                informationalRequiredAction: try validatedText(entry.requiredAction, field: "requiredAction", maximumLength: 32_768),
                notes: try validatedText(entry.notes, field: "notes", maximumLength: 32_768, allowEmpty: true),
                dateAdded: dateAdded,
                dueDate: dueDate,
                ransomwareCampaignUse: entry.knownRansomwareCampaignUse,
                sourceUpdatedAt: releasedAt,
                fetchedAt: fetchedAt,
                catalogURL: Self.catalogURL,
                nvdURL: URL(string: "https://nvd.nist.gov/vuln/detail/\(identifier)")!,
                applicability: .unknown
            )
            if let previous = byIdentifier[identifier], previous != vulnerability {
                throw FeedNormalizationError.duplicateConflict(identifier)
            }
            byIdentifier[identifier] = vulnerability
        }
        return NormalizedKEVCatalog(
            title: title, version: version, releasedAt: releasedAt, fetchedAt: fetchedAt,
            vulnerabilities: byIdentifier.values.sorted { $0.cveID < $1.cveID }
        )
    }

    private func normalizedCVEID(_ value: String) throws -> String {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CVE", parts[1].utf8.count == 4,
              parts[2].utf8.count >= 4, parts[2].utf8.count <= 19,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              parts[2].utf8.allSatisfy({ (48...57).contains($0) }),
              let year = Int(parts[1]), year >= 1999 else {
            // Do not echo arbitrary feed strings into errors or logs.
            throw FeedNormalizationError.invalidCVEIdentifier("cveID")
        }
        return identifier
    }

    private func validatedText(_ value: String, field: String, maximumLength: Int, allowEmpty: Bool = false) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= maximumLength, (allowEmpty || !text.isEmpty),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FeedNormalizationError.invalidField(field)
        }
        return text
    }

    private func timestamp(_ value: String, field: String) throws -> Date {
        guard value.utf8.count <= 64,
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#, options: .regularExpression) != nil else {
            throw FeedNormalizationError.invalidDate(field: field)
        }
        // ISO8601DateFormatter can normalize impossible calendar dates on some platforms.
        _ = try calendarDate(String(value.prefix(10)), field: field)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw FeedNormalizationError.invalidDate(field: field) }
        return date
    }

    private func calendarDate(_ value: String, field: String) throws -> Date {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }),
              let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)) else { throw FeedNormalizationError.invalidDate(field: field) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw FeedNormalizationError.invalidDate(field: field)
        }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year, checked.month == month, checked.day == day else {
            throw FeedNormalizationError.invalidDate(field: field)
        }
        return date
    }
}

private struct CatalogPayload: Decodable {
    let title: String
    let catalogVersion: String
    let dateReleased: String
    let count: Int
    let vulnerabilities: [VulnerabilityPayload]
}

private struct VulnerabilityPayload: Decodable {
    let cveID: String
    let vendorProject: String
    let product: String
    let vulnerabilityName: String
    let dateAdded: String
    let shortDescription: String
    let requiredAction: String
    let dueDate: String
    let knownRansomwareCampaignUse: RansomwareCampaignUse
    let notes: String
}
