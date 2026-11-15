import SwiftUI
import AppKit

// Note for contributors: view-local state uses ObservableObject rather than
// @State so the project also builds with the Command Line Tools alone, which
// ship without the SwiftUI macro plugin that @State now depends on.

@main
struct SwiftCloneApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Needed when launched as a bare executable (swift run); harmless in a bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("SwiftClone") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Backup Job") { model.addJob() }.keyboardShortcut("n")
            }
        }
    }
}
