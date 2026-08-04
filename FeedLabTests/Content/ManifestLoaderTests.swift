import Foundation
import Testing

@testable import FeedLab

@Suite("Manifest loading and licensing validation")
struct ManifestLoaderTests {
    private let loader = ManifestLoader()

    // MARK: - Happy path

    @Test("A well-formed manifest decodes into items with their source intact")
    func validManifestLoads() throws {
        let data = try Fixture.manifest(items: [
            Fixture.item(id: "a", title: "First"),
            Fixture.item(id: "b", title: "Second", url: "https://example.com/clip.mp4")
        ])

        let manifest = try loader.load(from: data)

        #expect(manifest.id == "test-manifest")
        #expect(manifest.items.count == 2)
        #expect(manifest.items.map(\.id) == ["a", "b"])
        #expect(manifest.items[0].source.license == "CC BY 3.0")
        #expect(manifest.items[0].source.attribution == "(CC) Blender Foundation")
    }

    @Test("Manifest order is preserved, because the run protocol depends on it")
    func orderIsPreserved() throws {
        let ids = ["z", "m", "a", "q"]
        let data = try Fixture.manifest(items: ids.map { Fixture.item(id: $0) })

        let manifest = try loader.load(from: data)

        #expect(manifest.items.map(\.id) == ids)
    }

    // MARK: - The licensing guardrail

    @Test("An item missing attribution fails validation rather than silently playing")
    func missingAttributionFails() throws {
        let data = try Fixture.manifest(items: [Fixture.item(omitting: "attribution")])

        #expect(throws: ManifestValidationError.missingItemField(index: 0, itemID: "item-1", field: "attribution")) {
            try loader.load(from: data)
        }
    }

    @Test(
        "Every required item field is enforced",
        arguments: ["id", "title", "url", "source", "license", "attribution"]
    )
    func missingRequiredFieldFails(field: String) throws {
        let data = try Fixture.manifest(items: [Fixture.item(omitting: field)])

        #expect(throws: ManifestValidationError.self) {
            try loader.load(from: data)
        }
    }

    @Test("A whitespace-only attribution credits nobody and is treated as absent")
    func blankAttributionFails() throws {
        let data = try Fixture.manifest(items: [Fixture.item(attribution: "   \n ")])

        #expect(throws: ManifestValidationError.missingItemField(index: 0, itemID: "item-1", field: "attribution")) {
            try loader.load(from: data)
        }
    }

    @Test("The failing item is identified by index even when its own id is missing")
    func missingIDReportsIndex() throws {
        let data = try Fixture.manifest(items: [
            Fixture.item(id: "ok"),
            Fixture.item(omitting: "id")
        ])

        #expect(throws: ManifestValidationError.missingItemField(index: 1, itemID: nil, field: "id")) {
            try loader.load(from: data)
        }
    }

    // MARK: - Structural validation

    @Test("Duplicate item ids are rejected, since records are keyed by item id")
    func duplicateIDFails() throws {
        let data = try Fixture.manifest(items: [Fixture.item(id: "dup"), Fixture.item(id: "dup")])

        #expect(throws: ManifestValidationError.duplicateItemID("dup")) {
            try loader.load(from: data)
        }
    }

    @Test("A non-HTTPS url is rejected so no entry can require an ATS exception")
    func insecureURLFails() throws {
        let data = try Fixture.manifest(items: [Fixture.item(url: "http://example.com/stream.m3u8")])

        #expect(throws: ManifestValidationError.insecureURL(itemID: "item-1", url: "http://example.com/stream.m3u8")) {
            try loader.load(from: data)
        }
    }

    @Test("An empty item list is rejected as a build mistake")
    func emptyManifestFails() throws {
        let data = try Fixture.manifest(items: [])

        #expect(throws: ManifestValidationError.emptyManifest) {
            try loader.load(from: data)
        }
    }

    @Test("Bytes that are not JSON produce a manifest error, not a decoding crash")
    func malformedJSONFails() {
        let data = Data("this is not json".utf8)

        #expect(throws: ManifestValidationError.self) {
            try loader.load(from: data)
        }
    }

    @Test("A missing bundle resource is reported by name")
    func missingResourceFails() {
        #expect(throws: ManifestValidationError.resourceNotFound(name: "no-such-manifest")) {
            try loader.load(resource: "no-such-manifest", in: .main)
        }
    }

    // MARK: - Stream format classification

    @Test(
        "Stream format is derived from the URL, including Smooth-Streaming-style .ism paths",
        arguments: [
            ("https://example.com/master.m3u8", StreamFormat.hls),
            ("https://example.com/bipbop_16x9_variant.m3u8", StreamFormat.hls),
            // The Unified Streaming shape: last path component is the dotfile-looking ".m3u8",
            // which `URL.pathExtension` reports as empty. Misclassifying this as progressive
            // would quietly drop a real HLS stream out of the ABR aggregates.
            ("https://example.com/tears-of-steel.ism/.m3u8", StreamFormat.hls),
            ("https://example.com/clip~medium.mp4", StreamFormat.progressive),
            ("https://example.com/movie.mov", StreamFormat.progressive)
        ]
    )
    func streamFormatIsDerivedFromURL(urlString: String, expected: StreamFormat) throws {
        let data = try Fixture.manifest(items: [Fixture.item(url: urlString)])

        let manifest = try loader.load(from: data)

        #expect(manifest.items[0].streamFormat == expected)
    }

    // MARK: - The shipped corpus

    @Test("The bundled short-form manifest is valid and meets the M1 item-count criterion")
    func shippedShortFormManifestIsValid() throws {
        let manifest = try loader.load(resource: "short-form", in: .main)

        #expect(manifest.items.count >= 20)
        #expect(!manifest.hlsItems.isEmpty)
        for item in manifest.items {
            #expect(!item.source.license.isEmpty, "\(item.id) has no license")
            #expect(!item.source.attribution.isEmpty, "\(item.id) has no attribution")
            #expect(item.url.scheme == "https", "\(item.id) is not HTTPS")
        }
    }

    @Test("The bundled measurement corpus is valid and contains only HLS")
    func shippedHLSOnlyManifestIsValid() throws {
        // The corpus every published comparison runs against. One progressive item slipping in
        // would put the 27% never-reaches-playback population back into the headline p90 while the
        // README says it was excluded — a discrepancy no number in the output would reveal.
        let manifest = try loader.load(resource: "hls-only", in: .main)

        #expect(!manifest.items.isEmpty)
        #expect(manifest.hlsItems.count == manifest.items.count, "the measurement corpus must be all HLS")

        // Every item must also exist in the full corpus, unchanged. The measurement manifest is a
        // subset, not a second corpus that could drift into different URLs or attributions.
        let full = try loader.load(resource: "short-form", in: .main)
        for item in manifest.items {
            let original = full.items.first { $0.id == item.id }
            #expect(original?.url == item.url, "\(item.id) differs from the full corpus")
            #expect(original?.source.attribution == item.source.attribution, "\(item.id) attribution differs")
        }
    }
}

// MARK: - Fixtures

private enum Fixture {
    /// Fields are optional so a test can omit exactly one and assert the resulting error.
    static func item(
        id: String? = "item-1",
        title: String? = "A Clip",
        url: String? = "https://example.com/stream.m3u8",
        source: String? = "Blender Foundation",
        license: String? = "CC BY 3.0",
        attribution: String? = "(CC) Blender Foundation"
    ) -> [String: Any] {
        var object: [String: Any] = [:]
        object["id"] = id
        object["title"] = title
        object["url"] = url
        object["source"] = source
        object["license"] = license
        object["attribution"] = attribution
        return object
    }

    static func item(omitting field: String) -> [String: Any] {
        var object = item()
        object.removeValue(forKey: field)
        return object
    }

    static func manifest(
        id: String? = "test-manifest",
        title: String? = "Test Manifest",
        items: [[String: Any]]
    ) throws -> Data {
        var object: [String: Any] = ["items": items]
        object["id"] = id
        object["title"] = title
        return try JSONSerialization.data(withJSONObject: object)
    }
}
