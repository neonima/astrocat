import SwiftUI

@main
struct AstroCatApp: App {
    var body: some Scene {
        WindowGroup("AstroCat") {
            AppShell()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1728, height: 1080)
    }
}
