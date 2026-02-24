import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store: SnippetStore
    let engine: TextExpansionEngine

    init() {
        let store = SnippetStore()
        self.store = store
        self.engine = TextExpansionEngine(store: store)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TextExpanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Expander", id: "mainWindow") {
            ContentView(store: model.store, engine: model.engine)
        }
        MenuBarExtra("Expander", systemImage: "text.bubble") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
