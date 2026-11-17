import SwiftUI

@main
struct EmailArchiverApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Bristlecone Email Archiver")
                .font(.title2)
            Text("Early development build. Import and sync arrive in later milestones.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
