import SwiftUI

@main
struct EqualizerMacAppApp: App {
    @StateObject private var model = EqualizerModel()
    @StateObject private var nowPlaying = NowPlayingService()
    @StateObject private var assistant = EQAssistantService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(nowPlaying)
                .environmentObject(assistant)
                .frame(minWidth: 1280, minHeight: 860)
        }
        .windowStyle(.titleBar)
    }
}
