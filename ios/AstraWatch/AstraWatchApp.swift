import SwiftUI

@main
struct AstraWatchApp: App {
    @StateObject private var link = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchHomeView()
            }
            .environmentObject(link)
        }
    }
}
