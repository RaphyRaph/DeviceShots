#if DEBUG
import AppKit

/// Debug-only launch options for checking and capturing the real app:
///   DEVICESHOTS_DEMO=1                      sample devices/slots; never saves or registers hotkeys
///   DEVICESHOTS_APPEARANCE=light|dark       force the app's appearance
///   DEVICESHOTS_SHOW_SETUP=ios|android      open a setup guide window
///   DEVICESHOTS_OPEN_SETTINGS=capture|shortcuts  open Settings on that tab
///   DEVICESHOTS_OPEN_MENU=1                 open the menu-bar menu
enum DebugHooks {
    private static let env = ProcessInfo.processInfo.environment

    static let isDemo = env["DEVICESHOTS_DEMO"] == "1"

    static var settingsTab: SettingsView.Section? {
        env["DEVICESHOTS_OPEN_SETTINGS"].flatMap { SettingsView.Section(rawValue: $0.capitalized) }
    }

    static var appearance: NSAppearance? {
        switch env["DEVICESHOTS_APPEARANCE"] {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }

    @MainActor
    static func applyAtLaunch(openMenu: @escaping @MainActor () -> Void) {
        // Setting the app-wide appearance stops the status-item menu from
        // opening programmatically, so the menu gets it directly instead.
        if env["DEVICESHOTS_OPEN_MENU"] != "1", let appearance {
            NSApp.appearance = appearance
        }
        if let guide = env["DEVICESHOTS_SHOW_SETUP"] {
            SetupWindow.show(guide == "ios" ? .ios : .android)
        }
        // Give the scenes (and the Settings bridge) a moment to come up.
        if settingsTab != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                SettingsOpener.open()
            }
        }
        if env["DEVICESHOTS_OPEN_MENU"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                openMenu()
            }
        }
    }
}
#endif
