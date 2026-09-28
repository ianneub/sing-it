import SwiftUI

@main
struct SingItApp: App {
    @State private var library = HymnLibrary()
    @State private var voice = VoiceProfile()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ScreenshotMode.screen {
                ScreenshotRoot(screen: screen)
            } else {
                HymnListView()
                    .environment(library)
                    .environment(voice)
            }
            #else
            HymnListView()
                .environment(library)
                .environment(voice)
            #endif
        }
    }
}
