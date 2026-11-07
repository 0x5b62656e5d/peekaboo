import Foundation

/// Holds the macOS assertion that limits the menu bar to the allowed apps' items.
final class MenuBarRestriction {
    private var token: Any?
    private var generation = 0

    /// The new assertion starts before the old one ends so the bar doesn't flash.
    func allow(only bundleIDs: [String], onFailure: @escaping (String) -> Void) {
        generation += 1
        let generation = generation
        PKBMenuBarRestrictionBegin(bundleIDs) { [weak self] token, error in
            guard let self, generation == self.generation else {
                if let token { PKBMenuBarRestrictionEnd(token) }
                return
            }
            self.replaceToken(with: token)
            if token == nil { onFailure(error?.localizedDescription ?? "Hiding failed") }
        }
    }

    func end() {
        generation += 1
        replaceToken(with: nil)
    }

    private func replaceToken(with new: Any?) {
        if let token { PKBMenuBarRestrictionEnd(token) }
        token = new
    }
}
