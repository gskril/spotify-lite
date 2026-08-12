import SwiftUI

struct NowPlayingBar: View {
    @ObservedObject var environment: AppEnvironment
    @State private var showingPlayer = false
    @State private var showingDevices = false
    @State private var isSendingCommand = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                fullBar
                compactBar
            }
            .padding(.horizontal, 18)
            .frame(height: 60)

            PlayerProgressTrack(environment: environment, showsTimes: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 7)
            .background(.regularMaterial)
        }
        .sheet(isPresented: $showingPlayer) {
            ExpandedPlayerView(environment: environment)
        }
    }

    private var fullBar: some View {
        HStack(spacing: 14) {
            trackSummary(width: 260)
            Spacer()
            playbackControls
            Spacer()
            deviceStatus
                .frame(width: 180, alignment: .trailing)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 12) {
            trackSummary(width: nil)
                .layoutPriority(1)
            Spacer(minLength: 4)
            playbackControls
            devicePickerButton(compact: true)
        }
    }

    private func trackSummary(width: CGFloat?) -> some View {
        Button { showingPlayer = true } label: {
            HStack(spacing: 11) {
                ArtworkView(url: track?.album?.images.first?.url, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.name ?? "Nothing playing")
                        .fontWeight(.semibold).lineLimit(1)
                    Text(track.map { $0.artists.map(\.name).joined(separator: ", ") } ?? playerSubtitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var playbackControls: some View {
        HStack(spacing: 17) {
            Button { previous() } label: { Image(systemName: "backward.fill") }
                .disabled(track == nil || isSendingCommand || environment.isStartingPlayback)
                .help("Previous")
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 31))
            }
            .disabled(isSendingCommand || environment.isStartingPlayback)
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")
            Button { next() } label: { Image(systemName: "forward.fill") }
                .disabled(track == nil || isSendingCommand || environment.isStartingPlayback)
                .help("Next")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var deviceStatus: some View {
        if environment.isStartingPlayback {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Connecting to this Mac…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            devicePickerButton(compact: false)
        }
    }

    private func devicePickerButton(compact: Bool) -> some View {
        Button { showingDevices.toggle() } label: {
            if compact {
                Image(systemName: "airplayaudio")
                    .foregroundStyle(environment.playback?.device?.isActive == true ? AppTheme.accent : .secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "airplayaudio")
                    Text(environment.playback?.device?.name ?? "Choose device")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(environment.playback?.device?.isActive == true ? AppTheme.accent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(environment.isStartingPlayback)
        .help("Choose a playback device")
        .popover(isPresented: $showingDevices, arrowEdge: .bottom) {
            DevicePickerView(environment: environment, isPresented: $showingDevices)
        }
    }

    private var track: SpotifyTrack? { environment.playback?.item }
    private var isPlaying: Bool { environment.playback?.isPlaying == true }
    private var receiverReady: Bool { if case .running = environment.spotifydState { return true }; return false }
    private var playerSubtitle: String {
        if environment.isStartingPlayback { return "Connecting to this Mac…" }
        return receiverReady ? "Choose something to play" : "Start the local receiver in Settings"
    }

    private func command(_ action: @escaping @Sendable () async throws -> Void) {
        isSendingCommand = true
        Task {
            do { try await action() }
            catch { environment.report(error) }
            environment.playback = await environment.playbackCoordinator.currentPlayback()
            isSendingCommand = false
        }
    }

    private func togglePlayback() {
        environment.togglePlayback()
    }

    private func previous() {
        let coordinator = environment.playbackCoordinator
        command { try await coordinator.previous() }
    }

    private func next() {
        let coordinator = environment.playbackCoordinator
        command { try await coordinator.next() }
    }

    private func playLocally() {
        environment.resumeLocally()
    }

}

private struct DevicePickerView: View {
    @ObservedObject var environment: AppEnvironment
    @Binding var isPresented: Bool

    @State private var devices: [SpotifyDevice] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var switchingDeviceID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to a device")
                        .font(.headline)
                    Text("Continue listening somewhere else")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await loadDevices(showLoading: false) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading || switchingDeviceID != nil)
                .help("Refresh devices")
            }
            .padding(16)

            Divider()

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Finding Spotify devices…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                        Button("Try Again") { Task { await loadDevices() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if devices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hifispeaker.2")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No devices found")
                            .fontWeight(.semibold)
                        Text("Open Spotify on another device, then refresh this list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(sortedDevices.enumerated()), id: \.offset) { _, device in
                                deviceRow(device)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
        .frame(width: 320)
        .task { await loadDevices() }
    }

    private var sortedDevices: [SpotifyDevice] {
        devices.sorted { lhs, rhs in
            if isCurrent(lhs) != isCurrent(rhs) { return isCurrent(lhs) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func deviceRow(_ device: SpotifyDevice) -> some View {
        let current = isCurrent(device)
        let unavailable = device.isRestricted || device.id == nil
        return Button {
            switchToDevice(device)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: deviceSymbol(for: device))
                    .font(.title3)
                    .foregroundStyle(current ? AppTheme.accent : .primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(unavailable ? "Unavailable for remote control" : (current ? "Currently playing" : deviceTypeLabel(device)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if switchingDeviceID == device.id {
                    ProgressView().controlSize(.small)
                } else if current {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current || unavailable || switchingDeviceID != nil)
        .help(unavailable ? "Spotify reports this device as unavailable for remote control." : "Play on \(device.name)")
    }

    private func isCurrent(_ device: SpotifyDevice) -> Bool {
        if device.isActive { return true }
        guard let id = device.id, let currentID = environment.playback?.device?.id else { return false }
        return id == currentID
    }

    private func switchToDevice(_ device: SpotifyDevice) {
        switchingDeviceID = device.id
        errorMessage = nil
        Task {
            do {
                try await environment.playbackCoordinator.transferPlayback(to: device)
                environment.playback = await environment.playbackCoordinator.currentPlayback()
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            switchingDeviceID = nil
        }
    }

    private func loadDevices(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        errorMessage = nil
        do {
            devices = try await environment.playbackCoordinator.availableDevices()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deviceSymbol(for device: SpotifyDevice) -> String {
        switch device.type.lowercased() {
        case "computer": "desktopcomputer"
        case "smartphone": "iphone"
        case "tablet": "ipad"
        case "tv": "tv"
        case "automobile", "automotive": "car.fill"
        case "game_console": "gamecontroller.fill"
        default: "hifispeaker.fill"
        }
    }

    private func deviceTypeLabel(_ device: SpotifyDevice) -> String {
        device.type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct ExpandedPlayerView: View {
    @ObservedObject var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var volume: Double = 50

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text("Now Playing").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ArtworkView(url: track?.album?.images.first?.url, size: 270, cornerRadius: 16)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            VStack(spacing: 5) {
                Text(track?.name ?? "Nothing playing").font(.title2.bold()).lineLimit(1)
                Text(track?.artists.map(\.name).joined(separator: ", ") ?? "Choose music from Home, Library, or Search")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 6) {
                PlayerProgressTrack(environment: environment, showsTimes: true)
            }
            HStack(spacing: 28) {
                Button { toggleShuffle() } label: { Image(systemName: environment.playback?.shuffle == true ? "shuffle.circle.fill" : "shuffle") }
                Button { run { try await environment.playbackCoordinator.previous() } } label: { Image(systemName: "backward.fill") }
                Button { togglePlayback() } label: { Image(systemName: environment.playback?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 42)) }
                Button { run { try await environment.playbackCoordinator.next() } } label: { Image(systemName: "forward.fill") }
                Button { cycleRepeat() } label: { Image(systemName: repeatSymbol) }
            }
            .buttonStyle(.plain)
            .font(.title3)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $volume, in: 0...100) { editing in if !editing { setVolume() } }
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
            .disabled(environment.playback?.device?.supportsVolume == false)
        }
        .padding(26)
        .frame(width: 430, height: 650)
        .onAppear {
            volume = Double(environment.playback?.device?.volumePercent ?? 50)
        }
    }

    private var track: SpotifyTrack? { environment.playback?.item }
    private var repeatSymbol: String {
        switch environment.playback?.repeatMode ?? .off {
        case .off: "repeat"
        case .context: "repeat.circle.fill"
        case .track: "repeat.1.circle.fill"
        }
    }

    private func togglePlayback() {
        environment.togglePlayback()
    }
    private func setVolume() { run { try await environment.playbackCoordinator.setVolume(Int(volume)) } }
    private func toggleShuffle() { run { try await environment.playbackCoordinator.setShuffle(environment.playback?.shuffle != true) } }
    private func cycleRepeat() {
        let current = environment.playback?.repeatMode ?? .off
        let next: RepeatMode = current == .off ? .context : (current == .context ? .track : .off)
        run { try await environment.playbackCoordinator.setRepeat(next) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                environment.playback = await environment.playbackCoordinator.currentPlayback()
            } catch { environment.report(error) }
        }
    }
}

private struct PlayerProgressTrack: View {
    @ObservedObject var environment: AppEnvironment
    let showsTimes: Bool

    @State private var displayedProgress: Double = 0
    @State private var isSeeking = false

    var body: some View {
        HStack(spacing: 9) {
            if showsTimes {
                Text(Int(displayedProgress).durationText)
                    .frame(width: 36, alignment: .trailing)
            }

            Slider(
                value: $displayedProgress,
                in: 0...duration,
                onEditingChanged: editingChanged
            )
            .controlSize(.small)
            .tint(AppTheme.accent)
            .disabled(track == nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Int(displayedProgress).durationText) of \(Int(duration).durationText)")

            if showsTimes {
                Text(Int(duration).durationText)
                    .frame(width: 36, alignment: .leading)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .onAppear { syncToPlayback() }
        .onChange(of: environment.playback?.progressMS) { _, _ in syncToPlayback() }
        .onChange(of: environment.playback?.item?.id) { _, _ in syncToPlayback() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard environment.playback?.isPlaying == true, !isSeeking else { continue }
                displayedProgress = min(duration, displayedProgress + 1_000)
            }
        }
    }

    private var track: SpotifyTrack? { environment.playback?.item }
    private var duration: Double { max(Double(track?.durationMS ?? 1), 1) }

    private func syncToPlayback() {
        guard !isSeeking else { return }
        displayedProgress = min(duration, Double(environment.playback?.progressMS ?? 0))
    }

    private func editingChanged(_ editing: Bool) {
        isSeeking = editing
        guard !editing else { return }
        let target = Int(displayedProgress)
        Task {
            do {
                try await environment.playbackCoordinator.seek(to: target)
                environment.playback = await environment.playbackCoordinator.currentPlayback()
            } catch {
                environment.report(error)
                syncToPlayback()
            }
        }
    }
}
