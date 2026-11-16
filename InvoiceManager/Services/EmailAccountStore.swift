import Foundation
import Security

struct EmailAccount: Codable, Equatable {
    var email: String
    var host: String
    var port: Int
    var useTLS: Bool

    static let presets: [(name: String, host: String, port: Int)] = [
        ("QQ 邮箱", "imap.qq.com", 993),
        ("网易 163", "imap.163.com", 993),
        ("网易 126", "imap.126.com", 993),
        ("Gmail", "imap.gmail.com", 993),
        ("Outlook", "outlook.office365.com", 993),
        ("自定义", "", 993)
    ]
}

enum EmailAccountStore {
    private static let accountKey = "email.account"
    private static let service = "com.example.InvoiceManager.email"

    static func saveAccount(_ account: EmailAccount) {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountKey)
        }
    }

    static func loadAccount() -> EmailAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey),
              let acc = try? JSONDecoder().decode(EmailAccount.self, from: data) else { return nil }
        return acc
    }

    static func clearAccount() {
        UserDefaults.standard.removeObject(forKey: accountKey)
        if let email = loadAccount()?.email {
            deletePassword(account: email)
        }
    }

    // MARK: - Keychain password

    static func savePassword(_ password: String, account: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
