import SingItCore
import SwiftUI

struct HymnListView: View {
    @Environment(HymnLibrary.self) private var library
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(library.search(query)) { hymn in
                NavigationLink(value: hymn.number) {
                    HStack(spacing: 12) {
                        Text(verbatim: String(hymn.number))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                        Text(hymn.title)
                    }
                }
            }
            .overlay {
                if library.hymns.isEmpty {
                    ContentUnavailableView("No hymns found", systemImage: "music.note.list",
                                           description: Text(library.loadErrors.first ?? "The app bundle has no hymn data."))
                }
            }
            .navigationTitle("Hymns")
            .searchable(text: $query, prompt: "Number or title")
            .navigationDestination(for: Int.self) { number in
                if let hymn = library.hymn(number: number) {
                    HymnSetupView(hymn: hymn)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RecordingsView()
                    } label: {
                        Label("Recordings", systemImage: "waveform")
                    }
                }
            }
        }
    }
}
