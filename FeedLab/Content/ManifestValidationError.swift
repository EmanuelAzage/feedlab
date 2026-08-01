import Foundation

/// Why a manifest was rejected.
///
/// Validation is explicit rather than a by-product of `Decodable`. Letting `JSONDecoder`
/// throw `.keyNotFound` for a missing `attribution` would technically fail the load, but
/// the error would read like a parsing bug instead of a licensing violation — and the
/// licensing rule is the one that actually matters here.
enum ManifestValidationError: Error, Equatable {
    /// The bytes were not valid JSON, or not the expected shape.
    case malformedJSON(String)
    /// A manifest-level field (`id`, `title`) was absent or blank.
    case missingManifestField(field: String)
    /// A manifest with no items is almost always a build-phase mistake, not intent.
    case emptyManifest
    /// A required item field was absent or blank. `index` is included because a blank
    /// `id` makes the item otherwise unidentifiable.
    case missingItemField(index: Int, itemID: String?, field: String)
    /// The `url` string could not be parsed as a URL.
    case invalidURL(itemID: String, raw: String)
    /// The URL was not HTTPS. Enforced so no manifest entry can quietly require an
    /// App Transport Security exception — weakening ATS app-wide to accommodate one
    /// test stream is a bad trade the validator refuses to let anyone make.
    case insecureURL(itemID: String, url: String)
    /// Two items shared an id. Records are keyed by item id, so duplicates would merge
    /// two different videos' metrics into one row.
    case duplicateItemID(String)
    /// The named resource was not present in the bundle.
    case resourceNotFound(name: String)
}

extension ManifestValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .malformedJSON(let detail):
            "Manifest is not valid JSON: \(detail)"
        case .missingManifestField(let field):
            "Manifest is missing required field '\(field)'."
        case .emptyManifest:
            "Manifest contains no items."
        case .missingItemField(let index, let itemID, let field):
            "Item at index \(index)\(itemID.map { " (id: \($0))" } ?? "") is missing required field '\(field)'."
        case .invalidURL(let itemID, let raw):
            "Item '\(itemID)' has an unparseable url: \(raw)"
        case .insecureURL(let itemID, let url):
            "Item '\(itemID)' uses a non-HTTPS url: \(url)"
        case .duplicateItemID(let itemID):
            "Duplicate item id '\(itemID)'."
        case .resourceNotFound(let name):
            "No manifest named '\(name).json' in the bundle."
        }
    }
}
