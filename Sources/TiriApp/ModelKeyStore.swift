import Foundation
import os
import Security
import TiriCore

/// Someone's API key, in the login keychain, never in a file. Plain Tiri and their own copy of it are
/// signed differently, so each is put on the item's list of apps that may read it: switching between
/// them never asks for the Mac's password. A test copy keeps an item of its own.
nonisolated enum ModelKeyStore {
    private static let account = "conversations"
    private static let cache = OSAllocatedUnfairLock<KeyedModel??>(initialState: nil)

    private static var service: String {
        let environment = ProcessInfo.processInfo.environment
        let isTest = Bundle.main.bundleIdentifier?.contains(".test.") == true && environment["TIRI_DEV_OFFSCREEN"] == "1"
        guard isTest else { return "Tiri API Key" }
        return "Tiri API Key (test copy \(environment["TIRI_HOME"] ?? ""))"
    }

    /// Read once, then remembered: it's asked for on every title.
    static var current: KeyedModel? {
        if let known = cache.withLock({ $0 }) { return known }
        let loaded = read()
        cache.withLock { $0 = .some(loaded) }
        return loaded
    }

    private static func read() -> KeyedModel? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeyedModel.self, from: data)
    }

    static func save(_ model: KeyedModel) throws {
        let data = try JSONEncoder().encode(model)
        remove()
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                                   kSecValueData as String: data]
        if let access = access() { item[kSecAttrAccess as String] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)"])
        }
        cache.withLock { $0 = .some(model) }
    }

    static func remove() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        cache.withLock { $0 = .some(nil) }
    }

    /// Written again with today's list of copies, when there's a key and one may have been made since.
    static func shareWithOtherCopies() {
        guard let model = current else { return }
        try? save(model)
    }

    /// This Tiri, and the other one if there is one: Plain Tiri for a personal copy, and the reverse.
    private static func access() -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        let others = [YourTiri.current.path, CopyState.load()?.plainPath].compactMap { $0 }
        for path in Set(others) where path != Bundle.main.bundlePath && FileManager.default.fileExists(atPath: path) {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
