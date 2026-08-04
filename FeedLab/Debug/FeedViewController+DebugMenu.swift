#if FEEDLAB_TOOLS
import SwiftUI
import UIKit

/// Debug-menu access, kept out of `FeedViewController` so the feed surface carries a single
/// `#if` (the install call) rather than being threaded with conditional compilation.
extension FeedViewController {
    /// Two entry points on purpose: shake is the convention and stays out of screenshots,
    /// but it is awkward on a simulator and impossible in a recorded run, so there is also a
    /// small persistent button.
    func installDebugAffordance() {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        button.tintColor = UIColor.white.withAlphaComponent(0.8)
        button.accessibilityLabel = "Debug menu"
        button.addTarget(self, action: #selector(presentDebugMenu), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc
    func presentDebugMenu() {
        guard presentedViewController == nil else { return }
        let menu = DebugMenuView(manifest: manifest, settings: toolsSettings) { [weak self] in
            self?.dismiss(animated: true) {
                guard let self else { return }
                // A sheet dismissal does not re-fire viewDidAppear on the presenter, so
                // first responder has to be reclaimed here or shake stops working.
                self.becomeFirstResponder()
                // Arm first: it resets the session, and the HUD reads session state. Applying it
                // second would leave the HUD showing the outgoing arm's aggregates for a tick.
                self.applyArm(self.toolsSettings.selectedArm)
                self.syncHUDVisibility()
                self.coordinator?.signposter.setEnabled(self.toolsSettings.areSignpostsEnabled)
            }
        }
        present(UIHostingController(rootView: menu), animated: true)
    }

    /// Applies the HUD toggle. Called when the debug menu closes rather than observed continuously,
    /// because the toggle is the only thing that changes it and a sheet dismissal is the moment the
    /// operator is done deciding.
    func syncHUDVisibility() {
        guard let hudController else { return }
        if toolsSettings.isHUDVisible, !hudController.isVisible {
            hudController.show()
        } else if !toolsSettings.isHUDVisible, hudController.isVisible {
            hudController.hide()
        }
    }
}
#endif
