import SwiftUI
import DeviceShotsKit

@main
struct DeviceShotsApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle

    var body: some Scene {
        DeviceShotsScenes()
    }
}
