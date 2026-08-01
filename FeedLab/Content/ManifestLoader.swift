import Foundation

/// Decodes and validates feed manifests.
///
/// The `Data` overload is the whole of the logic; the `Bundle` overload only locates
/// bytes. That split is what makes licensing validation unit-testable without a bundle,
/// a device, or a network — see `docs/testing.md`.
struct ManifestLoader {
    // MARK: - Loading

    func load(from data: Data) throws -> Manifest {
        let dto: ManifestDTO
        do {
            dto = try JSONDecoder().decode(ManifestDTO.self, from: data)
        } catch {
            throw ManifestValidationError.malformedJSON(error.localizedDescription)
        }
        return try validate(dto)
    }

    func load(resource name: String, in bundle: Bundle) throws -> Manifest {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw ManifestValidationError.resourceNotFound(name: name)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestValidationError.malformedJSON(error.localizedDescription)
        }
        return try load(from: data)
    }

    // MARK: - Validation

    private func validate(_ dto: ManifestDTO) throws -> Manifest {
        let id = try require(dto.id, manifestField: "id")
        let title = try require(dto.title, manifestField: "title")

        let itemDTOs = dto.items ?? []
        guard !itemDTOs.isEmpty else { throw ManifestValidationError.emptyManifest }

        var items: [FeedItem] = []
        var seenIDs: Set<String> = []
        items.reserveCapacity(itemDTOs.count)

        for (index, itemDTO) in itemDTOs.enumerated() {
            let item = try validate(itemDTO, at: index)
            guard seenIDs.insert(item.id).inserted else {
                throw ManifestValidationError.duplicateItemID(item.id)
            }
            items.append(item)
        }

        return Manifest(id: id, title: title, items: items)
    }

    private func validate(_ dto: ItemDTO, at index: Int) throws -> FeedItem {
        let id = try require(dto.id, itemField: "id", index: index, itemID: dto.id)
        let title = try require(dto.title, itemField: "title", index: index, itemID: id)
        let rawURL = try require(dto.url, itemField: "url", index: index, itemID: id)
        let sourceName = try require(dto.source, itemField: "source", index: index, itemID: id)
        // The two fields the licensing guardrail exists to enforce.
        let license = try require(dto.license, itemField: "license", index: index, itemID: id)
        let attribution = try require(dto.attribution, itemField: "attribution", index: index, itemID: id)

        guard let url = URL(string: rawURL) else {
            throw ManifestValidationError.invalidURL(itemID: id, raw: rawURL)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw ManifestValidationError.insecureURL(itemID: id, url: rawURL)
        }

        return FeedItem(
            id: id,
            title: title,
            url: url,
            source: ContentSource(name: sourceName, license: license, attribution: attribution)
        )
    }

    /// Treats a whitespace-only value as absent — `"attribution": "  "` satisfies a
    /// non-nil check while crediting nobody, which is exactly the failure this guards.
    private func require(_ value: String?, manifestField field: String) throws -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw ManifestValidationError.missingManifestField(field: field)
        }
        return trimmed
    }

    private func require(
        _ value: String?,
        itemField field: String,
        index: Int,
        itemID: String?
    ) throws -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw ManifestValidationError.missingItemField(index: index, itemID: itemID, field: field)
        }
        return trimmed
    }
}

// MARK: - Wire format

/// Every field is optional at the decoding layer so that "absent" becomes a validation
/// decision we control, not a `DecodingError` thrown before we can describe it.
private struct ManifestDTO: Decodable {
    let id: String?
    let title: String?
    let items: [ItemDTO]?
}

private struct ItemDTO: Decodable {
    let id: String?
    let title: String?
    let url: String?
    let source: String?
    let license: String?
    let attribution: String?
}
