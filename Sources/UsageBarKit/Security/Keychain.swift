import Foundation
import Security

/// Thin wrapper over the macOS Keychain (Security.framework), used to read the
/// generic-password credential blobs that CLIs like Claude Code, Codex, and the
/// GitHub CLI store there.
///
/// Reading another app's keychain item triggers a one-time macOS prompt
/// ("UsageBar wants to use the credentials stored in 'Claude Code-credentials'").
/// Click "Always Allow" once. That prompt is the operating system enforcing the
/// boundary on your behalf — it's a feature, not a bug, and it's exactly why a
/// local tool you built is safer than a third-party app: nothing reads these
/// secrets without you explicitly authorizing this specific binary.
enum Keychain {

    /// Read a generic-password item's value as a UTF-8 string.
    /// `account` is optional; pass it when a service holds multiple accounts.
    static func readGenericPassword(service: String, account: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            // Match both local and iCloud-synced items.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account = account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.info("Keychain read '\(service)' status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Update an existing generic-password item's value. Used ONLY by the
    /// opt-in token-refresh path, and only to write a freshly-minted token back
    /// to the exact item we read it from, so the owning CLI stays in sync.
    ///
    /// We deliberately only UPDATE existing items — we never CREATE keychain
    /// items for other services. If the item doesn't already exist, this is a
    /// no-op failure rather than us inventing a credential store.
    @discardableResult
    static func updateGenericPassword(service: String, account: String? = nil, value: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account = account {
            query[kSecAttrAccount as String] = account
        }
        let attrs: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status != errSecSuccess {
            Log.warn("Keychain update '\(service)' failed status=\(status)")
        }
        return status == errSecSuccess
    }
}
