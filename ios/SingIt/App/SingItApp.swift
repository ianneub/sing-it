import SwiftUI

@main
struct SingItApp: App {
    @State private var library = HymnLibrary()
    @State private var voice = VoiceProfile()

    var body: some Scene {
        WindowGroup {
            HymnListView()
                .environment(library)
                .environment(voice)
        }
    }
}
