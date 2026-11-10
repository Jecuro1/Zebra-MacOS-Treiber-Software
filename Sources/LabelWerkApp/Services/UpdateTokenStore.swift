import Foundation
import Security

/// Zugriffstoken für Updates aus einem **privaten** GitHub-Repository – ausschließlich im
/// Schlüsselbund des Benutzers (generisches Passwort, Dienst `com.labelwerk.app.update`,
/// Account = Repository „Besitzer/Name“).
///
/// Der Token wird nirgends sonst gespeichert, nicht protokolliert und nur an GitHub gesendet
/// (`UpdateClient`). Lesen kann eine Rückfrage von macOS auslösen („LabelWerk möchte auf … in
/// Ihrem Schlüsselbund zugreifen“), etwa wenn sich die Signatur der App mit einem Update geändert
/// hat – deshalb liest `UpdateController` den Wert nicht auf dem Main-Thread und höchstens einmal
/// je Programmstart.
enum UpdateTokenStore {
    /// Dienstname des Schlüsselbund-Eintrags.
    static let service = "com.labelwerk.app.update"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
                return tr("Der Schlüsselbund meldet einen Fehler: %@", message)
            }
        }
    }

    private static func query(for repository: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repository,
        ]
    }

    /// `true`, wenn für `repository` ein Token gespeichert ist. Liest nur die Attribute, nicht das
    /// Geheimnis (keine Rückfrage des Schlüsselbunds).
    static func hasToken(repository: String) -> Bool {
        var query = query(for: repository)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Gespeicherter Token für `repository` (`nil`, wenn keiner gespeichert ist oder der Zugriff
    /// verweigert wurde). Kann blockieren, solange macOS nach der Freigabe fragt.
    static func read(repository: String) -> String? {
        var query = query(for: repository)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Speichert (oder ersetzt) den Token für `repository`.
    static func save(_ token: String, repository: String) throws {
        let data = Data(token.utf8)
        let base = query(for: repository)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = base
            item[kSecValueData as String] = data
            // Name und Art erscheinen in der Schlüsselbundverwaltung und in Rückfragen von macOS.
            item[kSecAttrLabel as String] = "LabelWerk – GitHub (\(repository))"
            item[kSecAttrDescription as String] = tr("Zugriffstoken für LabelWerk-Updates")
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.keychain(added) }
        default:
            throw StoreError.keychain(status)
        }
    }

    /// Entfernt den Token für `repository` (kein Fehler, wenn keiner gespeichert ist).
    static func delete(repository: String) throws {
        let status = SecItemDelete(query(for: repository) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}
