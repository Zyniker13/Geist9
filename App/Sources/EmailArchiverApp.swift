// App entry (DESIGN 12): one window, three columns — archive controls and
// mailboxes, the message list, the viewer. All state lives in ArchiveModel.

import SwiftUI

@main
struct EmailArchiverApp: App {
    @StateObject private var model = ArchiveModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
