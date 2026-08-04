#if FEEDLAB_TOOLS
import Foundation
import Observation

/// Toggles for the measurement tooling.
///
/// `@Observable` rather than a store with persistence: these are per-launch operator preferences,
/// and a HUD that silently stayed on from a previous session could end up perturbing a run nobody
/// intended it to be part of.
@MainActor
@Observable
final class ToolsSettings {
    /// The HUD defaults to **off**. Its own acceptance criterion is that enabling it does not
    /// measurably change time-to-first-frame — which can only be checked by comparing against runs
    /// with it off, so off has to be the baseline.
    var isHUDVisible = false

    /// Selected by name rather than by value: `Arm` holds an `any PreloadStrategy` and so is not
    /// `Equatable`, and the name is what records and screenshots carry anyway.
    ///
    /// Starts at the control, so a launch that touches nothing measures what the engine did before
    /// arms existed.
    var selectedArmName = ArmRegistry.control.name

    var selectedArm: Arm {
        ArmRegistry.arm(named: selectedArmName) ?? ArmRegistry.control
    }
}
#endif
