#if FEEDLAB_TOOLS
import SwiftUI

/// The rig's control surface.
///
/// Deliberately contains only controls whose subsystem exists — a menu full of inert switches would
/// be indistinguishable from a menu full of broken ones.
struct DebugMenuView: View {
    let manifest: Manifest
    @Bindable var settings: ToolsSettings
    /// Passed through to the dashboard. The same store the coordinator seals into, so what the
    /// dashboard shows is what was actually written rather than a second view of memory.
    let store: SessionStore?
    /// Explicit rather than `@Environment(\.dismiss)` so the presenter can restore first
    /// responder afterwards — without that, the shake gesture works exactly once.
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                armSection
                measurementSection
                resultsSection
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

    /// The experiment selector.
    ///
    /// Shows the arm's hypothesis, its strategy and its pool capacity together, because an arm *is*
    /// those three things — a picker that showed only a name would let the operator select
    /// `preload3-capped` without seeing that it also changes pool capacity from 3 to 4.
    private var armSection: some View {
        Section {
            Picker("Arm", selection: $settings.selectedArmName) {
                ForEach(ArmRegistry.all) { arm in
                    Text(arm.name).tag(arm.name)
                }
            }
            LabeledContent("Strategy", value: settings.selectedArm.strategy.name)
            LabeledContent("Pool capacity", value: Self.describe(settings.selectedArm.poolCapacity))
        } header: {
            Text("Experiment arm")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(settings.selectedArm.hypothesis)
                Text(
                    """
                    Applied on Done. Selecting an arm **resets the session** and returns to the \
                    first item: records carry the arm name, and peak memory is a session figure, \
                    so a session spanning two arms would attribute items to the wrong condition \
                    and a memory peak to neither.
                    """
                )
            }
        }
    }

    private static func describe(_ capacity: PoolCapacity) -> String {
        switch capacity {
        case .bounded(let limit): "\(limit)"
        case .unbounded: "Unbounded"
        }
    }

    private var measurementSection: some View {
        Section {
            Toggle("Live HUD", isOn: $settings.isHUDVisible)
            Toggle("Signposts", isOn: $settings.areSignpostsEnabled)
        } header: {
            Text("Measurement")
        } footer: {
            Text(
                """
                The HUD is off by default. M4's criterion is that enabling it does not measurably \
                change time-to-first-frame, which can only be checked against runs with it off.

                Signposts are on by default — they render nothing and sample nothing, and they are \
                what makes an Instruments trace readable. Turn them off to make a run's overhead \
                provably absent rather than merely small.
                """
            )
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            NavigationLink("Dashboard") {
                DashboardView(store: store)
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
