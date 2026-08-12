import SwiftUI

struct SpotifyLiteCommands: Commands {
    @ObservedObject var environment: AppEnvironment

    var body: some Commands {
        CommandMenu("Navigate") {
            destinationButton(.home, key: "1")
            destinationButton(.library, key: "2")
            destinationButton(.search, key: "3")
            destinationButton(.settings, key: "4")
            Divider()
            Button("Focus Search") { environment.requestSearchFocus() }
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(environment.playback?.isPlaying == true ? "Pause (Space)" : "Play (Space)") {
                environment.togglePlayback()
            }
            Button("Previous") { environment.skipPrevious() }
            Button("Next") { environment.skipNext() }
            Divider()
            Button("Volume Up") { environment.adjustVolume(by: 5) }
            Button("Volume Down") { environment.adjustVolume(by: -5) }
        }
    }

    private func destinationButton(_ destination: AppDestination, key: KeyEquivalent) -> some View {
        Button(destination.title) { environment.navigate(to: destination) }
            .keyboardShortcut(key, modifiers: .command)
    }
}
