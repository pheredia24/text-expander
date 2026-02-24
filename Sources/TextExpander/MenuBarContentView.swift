import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Open snippets") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "mainWindow")
            }
            Divider()

            Button("Quit Expander") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 200)
    }
}
