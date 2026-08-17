import SwiftUI

@main
struct AstroCatApp: App {
    init() {
        // Before any window exists: the diagnostic drives the model directly and
        // prints what reached the shader, which is not something the UI can be
        // asked about from outside.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            MainActor.assumeIsolated { SelfTest.run(args[i + 1]) }
        }
    }

    var body: some Scene {
        WindowGroup("AstroCat") {
            AppShell()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1728, height: 1080)
    }
}
