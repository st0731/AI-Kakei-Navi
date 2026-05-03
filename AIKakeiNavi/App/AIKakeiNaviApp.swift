import SwiftUI
import SwiftData

@main
struct AIKakeiNaviApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: SavedReceipt.self)
    }
}
