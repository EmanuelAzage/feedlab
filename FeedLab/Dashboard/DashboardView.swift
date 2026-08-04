#if FEEDLAB_TOOLS
import SwiftUI

/// Stored sessions, charted by arm, with export.
///
/// Reachable from the debug menu (`docs/product-spec.md`). Renders nothing invented: an arm with no
/// runs is absent rather than zero, and every chart carries its n.
struct DashboardView: View {
    @State private var model: DashboardModel
    @State private var exportURL: URL?
    @State private var isShowingDeleteConfirmation = false

    init(store: SessionStore?) {
        _model = State(initialValue: DashboardModel(store: store))
    }

    var body: some View {
        List {
            if model.loadFailed {
                unavailableSection
            } else if model.isEmpty {
                emptySection
            } else {
                chartsSection
                sessionsSection
                exportSection
            }
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .sheet(item: $exportURL) { url in
            ShareSheet(url: url)
        }
        .confirmationDialog(
            "Delete every stored session?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                Task { await model.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Device runs are expensive to repeat. Export first if these numbers matter.")
        }
    }

    // MARK: - States

    private var unavailableSection: some View {
        Section {
            Label("Session store unavailable", systemImage: "exclamationmark.triangle")
            Text("Sessions are not being persisted. Nothing from this launch will reach the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptySection: some View {
        Section {
            Text("No sessions yet.")
            Text(
                """
                A session is sealed when you change arm or background the app. Scroll a few items \
                first — an arm selected and immediately changed measured nothing, and is not stored.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Charts

    private var chartsSection: some View {
        Section {
            StartupVsSmoothnessChart(results: model.results)
            StartupByArmChart(results: model.results)
            StartupDistributionChart(results: model.results)
            RebufferByArmChart(results: model.results)
            PeakMemoryByArmChart(results: model.results)
            if let session = model.sessions.first {
                BitrateOverTimeChart(session: session)
            }
        } header: {
            Text("Comparison")
        } footer: {
            Text(
                """
                Manual selection, not randomised — a single-operator rig, not an online experiment. \
                Numbers from a simulator or an unoptimized build describe the host and the build \
                settings rather than the design; only Measure-configuration device runs are \
                publishable.
                """
            )
        }
    }

    // MARK: - Runs

    private var sessionsSection: some View {
        Section("Runs (\(model.runCount))") {
            ForEach(model.results) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(result.arm).font(.headline)
                        Spacer()
                        Text("n=\(result.runCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(Self.describe(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Optionals render as `—`, never as `0` — the same rule the CSV export follows.
    private static func describe(_ result: ArmResult) -> String {
        let startup = result.medianP90TimeToFirstFrame.map { String(format: "%.0f ms", $0 * 1000) } ?? "—"
        let ratio = result.medianRebufferRatio.map { String(format: "%.3f", $0) } ?? "—"
        let memory = result.medianPeakMemoryBytes.map {
            String(format: "%.1f MB", Double($0) / 1_048_576)
        } ?? "—"
        return "p90 \(startup) · rebuffer \(ratio) · peak \(memory) · \(result.itemCount) items"
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Button("Export CSV") {
                guard let data = model.csv().data(using: .utf8) else { return }
                exportURL = model.exportFile(named: "feedlab-sessions.csv", contents: data)
            }
            Button("Export JSON") {
                guard let data = model.json() else { return }
                exportURL = model.exportFile(named: "feedlab-sessions.json", contents: data)
            }
            Button("Delete all sessions", role: .destructive) {
                isShowingDeleteConfirmation = true
            }
        } header: {
            Text("Export")
        } footer: {
            Text(
                """
                The README's results table is generated from the CSV, never typed by hand — that is \
                what keeps a published number traceable to a measured one. JSON carries the raw \
                events too, so a metric definition can change without repeating the runs.
                """
            )
        }
    }
}

/// `UIActivityViewController`, which SwiftUI still has no native equivalent for on iOS 17.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// So a `URL` can drive `.sheet(item:)` directly.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
