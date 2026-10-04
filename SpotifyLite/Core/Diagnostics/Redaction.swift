import Foundation

enum Redaction {
    /// Truncates and strips OAuth secrets, credentials, and bearer tokens before text is
    /// logged or shown.
    static func redact(_ value: String) -> String {
        var redacted = String(value.prefix(4_096))
        let querySecret = #"(?i)(access_token|refresh_token|code|state|password|username)=([^&\s]+)"#
        redacted = redacted.replacingOccurrences(
            of: querySecret,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*"#,
            with: "Bearer <redacted>",
            options: .regularExpression
        )
        return redacted
    }
}
