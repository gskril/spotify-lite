import SwiftUI
import AppKit

@MainActor
final class SpotifyLiteAppDelegate: NSObject, NSApplicationDelegate {
    var spotifyd: (any SpotifydManaging)?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This process owns the local audio receiver. AppKit's automatic/sudden termination
        // would otherwise tear down active playback when the app has been idle or hidden.
        ProcessInfo.processInfo.disableAutomaticTermination("Spotify Lite manages local playback")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.invalidateRestorableState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        for window in NSApp.windows { configure(window) }
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configure(window)
    }

    private func configure(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        WindowPlacement.ensureUsable(window)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = sender.windows.first(where: { $0.contentViewController != nil }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let spotifyd else { return .terminateNow }
        terminationPending = true
        Task {
            await spotifyd.stopKeepingAlive()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct SpotifyLiteApp: App {
    @NSApplicationDelegateAdaptor(SpotifyLiteAppDelegate.self) private var appDelegate
    @StateObject private var environment: AppEnvironment

    init() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let clientIDStore = SpotifyClientIDStore()
        let authorizer = SpotifyAuthorizer(clientIDStore: clientIDStore)
        let api = SpotifyAPIClient(authorizer: authorizer)
        let spotifyd = SpotifydSupervisor()
        let playbackCoordinator = PlaybackCoordinator(
            api: api,
            spotifyd: spotifyd,
            receiverName: SpotifydSupervisorConfiguration.defaultDeviceName
        )
        _environment = StateObject(wrappedValue: AppEnvironment(
            authorizer: authorizer,
            api: api,
            spotifyd: spotifyd,
            playbackCoordinator: playbackCoordinator
        ))
        appDelegate.spotifyd = spotifyd
    }

    var body: some Scene {
        WindowGroup("Spotify Lite") {
            RootView(environment: environment)
                .frame(minWidth: 760, minHeight: 580)
                .background(WindowPresentationGuard().frame(width: 0, height: 0))
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 720)
        .defaultLaunchBehavior(.presented)
        .commands { SpotifyLiteCommands(environment: environment) }

        Settings {
            SettingsView(environment: environment)
                .frame(minWidth: 660, minHeight: 560)
        }
    }
}
