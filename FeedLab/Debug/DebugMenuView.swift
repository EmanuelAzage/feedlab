#if FEEDLAB_TOOLS
import SwiftUI

/// The rig's control surface.
///
/// Deliberately contains only controls whose subsystem exists. Arm selection arrives with
/// `ArmRegistry` (M5), HUD and signpost toggles with the instrumentation they gate (M3–M4),
/// and session start/stop/export with `SessionStore` (M5). A menu full of inert switches
/// would be indistinguishable from a menu full of broken ones.
struct DebugMenuView: View {
    let manifest: Manifest
    /// Explicit rather than `@Environment(\.dismiss)` so the presenter can restore first
    /// responder afterwards — without that, the shake gesture works exactly once.
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                contentSection
                buildSection
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private var contentSection: some View {
        Section("Content") {
            LabeledContent("Manifest", value: manifest.title)
            LabeledContent("Items", value: "\(manifest.items.count)")
            // Surfaced because it bounds which metrics are interpretable: bitrate-switch
            // counts are meaningful only over the HLS subset.
            LabeledContent("HLS / progressive", value: "\(hlsCount) / \(progressiveCount)")
            NavigationLink("Credits") {
                CreditsView(manifest: manifest)
            }
        }
    }

    private var buildSection: some View {
        Section {
            LabeledContent("Configuration", value: BuildInfo.configuration.rawValue)
            LabeledContent("Optimized", value: BuildInfo.isOptimized ? "Yes" : "No")
            LabeledContent("Version", value: "\(BuildInfo.version) (\(BuildInfo.build))")
        } header: {
            Text("Build")
        } footer: {
            if !BuildInfo.isOptimized {
                Label(
                    """
                    Unoptimized build. Numbers from this configuration describe the build \
                    settings, not the design — they are not publishable. Measurement runs \
                    use the Measure configuration on a physical device.
                    """,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private var hlsCount: Int {
        manifest.hlsItems.count
    }

    private var progressiveCount: Int {
        manifest.items.count - hlsCount
    }
}

/// Per-item attribution, required by `docs/content-sources.md`.
struct CreditsView: View {
    let manifest: Manifest

    var body: some View {
        List {
            ForEach(groupedBySource, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.source.attribution)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.source.license)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groupedBySource: [(source: String, items: [FeedItem])] {
        Dictionary(grouping: manifest.items) { $0.source.name }
            .map { (source: $0.key, items: $0.value) }
            .sorted { $0.source < $1.source }
    }
}
#endif
