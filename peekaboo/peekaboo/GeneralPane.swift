import SwiftUI
import Truss

extension SettingsPane {
    static func general(onChange: @escaping () -> Void) -> SettingsPane {
        SettingsPane("General", systemImage: "gearshape.fill") {
            GeneralSections(onChange: onChange)
            SettingsDataSection()
        }
    }
}

/// Seeded from Settings and written back through its setters, which aren't observable. onChange tells the
/// hider about the choices that change what's in the menu bar.
private struct GeneralSections: View {
    let onChange: () -> Void

    @State private var hidesAppMenus = Settings.hidesAppMenus
    @State private var glyph = Settings.glyph
    @State private var revealMode = Settings.revealMode
    @State private var autoHidesIcons = Settings.autoHidesIcons
    @State private var autoHideDelay = Settings.autoHideDelay
    @State private var hidesClock = Settings.hiddenSystemItems.contains(.clock)
    @State private var hidesControlCenter = Settings.hiddenSystemItems.contains(.controlCenter)

    var body: some View {
        Section("Startup") {
            StartAtLoginToggle()
        }

        Section("Menu Bar") {
            Toggle("Hide app menus until hovered", isOn: $hidesAppMenus)

            Picker("Divider icon", selection: $glyph) {
                ForEach(DividerGlyph.allCases, id: \.self) { Text($0.title) }
            }

            Picker("Show hidden icons", selection: $revealMode) {
                ForEach(RevealMode.allCases, id: \.self) { Text($0.title) }
            }
        }

        Section {
            Toggle("Hide icons automatically", isOn: $autoHidesIcons)

            if autoHidesIcons {
                LabeledContent("Hide after") {
                    Slider(value: $autoHideDelay, in: 0...10, step: 0.5)
                    Text(String(format: "%.1fs", autoHideDelay))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Hide the clock", isOn: $hidesClock)
            Toggle("Hide Control Center", isOn: $hidesControlCenter)
        } header: {
            Text("Hidden Icons")
        } footer: {
            Text("⌘-drag menu bar icons left of the divider to hide them, or right of it to keep them visible. An app's icons hide together. Apple's own icons stay visible, apart from the clock and Control Center if you hide them.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: hidesAppMenus) { Settings.hidesAppMenus = hidesAppMenus }
        .onChange(of: glyph) {
            Settings.glyph = glyph
            onChange()
        }
        .onChange(of: revealMode) {
            Settings.revealMode = revealMode
            onChange()
        }
        .onChange(of: autoHidesIcons) { Settings.autoHidesIcons = autoHidesIcons }
        .onChange(of: autoHideDelay) { Settings.autoHideDelay = autoHideDelay }
        .onChange(of: hidesClock) { saveSystemItems() }
        .onChange(of: hidesControlCenter) { saveSystemItems() }
    }

    private func saveSystemItems() {
        var items = Set<SystemItem>()
        if hidesClock { items.insert(.clock) }
        if hidesControlCenter { items.insert(.controlCenter) }
        Settings.hiddenSystemItems = items
        onChange()
    }
}
