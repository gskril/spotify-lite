import SwiftUI

struct SpotifyLiteCommands: Commands {
    @ObservedObject var environment: AppEnvironment

    var body: some Commands {
        // One window: a second one would run a duplicate set of receiver and playback observers.
        CommandGroup(replacing: .newItem) {}

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
            // Option-Command keeps plain Command-arrows free for text editing in Search.
            Button("Previous") { environment.skipPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next") { environment.skipNext() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button("Volume Up") { environment.adjustVolume(by: 5) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { environment.adjustVolume(by: -5) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    private func destinationButton(_ destination: AppDestination, key: KeyEquivalent) -> some View {
        Button(destination.title) { environment.navigate(to: destination) }
            .keyboardShortcut(key, modifiers: .command)
    }
}
