import Foundation
import Security

struct SoloistSupervisorConfiguration: Sendable {
    var userSelectedExecutableURL: URL?
    var applicationSupportDirectory: URL
    var deviceName: String
    var maxCacheSizeMB: Int
    var logTailLineLimit: Int
    var logFileMaxBytes: Int
    var gracefulStopDelay: Duration
    var keepAliveRestartDelay: Duration
    var pairingTimeout: Duration

    /// Spotify publishes Soloist builds here and does not allow redistributing them.
    static let downloadsURL = URL(
        string: "https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates"
    )!
    static let apiKeyDashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    /// Soloist refuses to start this long after its build date (exit status 10).
    static let buildLifetimeDays = 90
    static let expiredBuildExitStatus: Int32 = 10
    /// The receiver volume the app last saw. Soloist otherwise starts every launch at 40%.
    static let rememberedVolumeKey = "receiver.volumePercent"
    static var rememberedVolume: Int {
        let stored = UserDefaults.standard.object(forKey: rememberedVolumeKey) as? Int
        return min(100, max(0, stored ?? 100))
    }

    init(
        userSelectedExecutableURL: URL? = nil,
        applicationSupportDirectory: URL = Self.defaultApplicationSupportDirectory,
        deviceName: String = Self.defaultDeviceName,
        maxCacheSizeMB: Int = 1_000,
        logTailLineLimit: Int = 300,
        logFileMaxBytes: Int = 512_000,
        gracefulStopDelay: Duration = .seconds(2),
        keepAliveRestartDelay: Duration = .seconds(1),
        pairingTimeout: Duration = .seconds(300)
    ) {
        self.userSelectedExecutableURL = userSelectedExecutableURL
        self.applicationSupportDirectory = applicationSupportDirectory
        self.deviceName = deviceName
        // Soloist rejects limits below 100 MB.
        self.maxCacheSizeMB = max(100, maxCacheSizeMB)
        self.logTailLineLimit = max(1, logTailLineLimit)
        self.logFileMaxBytes = max(8_192, logFileMaxBytes)
        self.gracefulStopDelay = gracefulStopDelay
        self.keepAliveRestartDelay = keepAliveRestartDelay
        self.pairingTimeout = pairingTimeout
    }

    static var defaultApplicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("SpotifyLite", isDirectory: true)
    }

    static var defaultDeviceName: String {
        let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Spotify Lite — \((hostName?.isEmpty == false ? hostName : nil) ?? "Mac")"
    }

    /// Where the user places the downloaded `soloist` executable.
    var installDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Soloist", isDirectory: true)
    }

    /// Soloist keeps its device identity and paired session here.
    var dataDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("soloist-data", isDirectory: true)
    }

    var cacheDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("soloist-cache", isDirectory: true)
    }

    var logDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }
}

/// The user's personal Soloist API key. Soloist requires it on every launch.
enum SoloistAPIKeyStore {
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.spotifylite.SpotifyLite.soloist",
            kSecAttrAccount as String: "api-key"
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Saves the key, or removes it when `key` is blank.
    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }
}
