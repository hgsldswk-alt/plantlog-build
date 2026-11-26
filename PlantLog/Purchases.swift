import Foundation
import Security
import StoreKit

actor TrialVault {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hgsldswk.plantlog.trial", kSecAttrAccount as String: "entitlement-v1"]

    func load(at now: Date) throws -> Entitlement {
        if Launch.testing {
            let start = now.addingTimeInterval(Launch.arguments.contains("-expired") ? -31 * 86400 : -8 * 86400)
            return Entitlement(firstOpen: start, disclosedTrial: true)
        }
        var result: CFTypeRef?
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound {
            let value = Entitlement(firstOpen: now)
            try save(value)
            return value
        }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.invalid }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    func save(_ value: Entitlement) throws {
        guard !Launch.testing else { return }
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StoreError.invalid }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw StoreError.invalid }
    }
}

enum Purchases {
    static var proID: String { Bundle.main.object(forInfoDictionaryKey: "PlantProProductID") as? String ?? "com.hgsldswk.plantlog.pro" }
    static var trialID: String { Bundle.main.object(forInfoDictionaryKey: "PlantTrialProductID") as? String ?? "com.hgsldswk.plantlog.trial" }

    static func status() async -> (purchased: Bool?, receiptDate: Date?) {
        var purchased: Bool? = false
        var receiptDate: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                guard transaction.revocationDate == nil else { continue }
                if transaction.productID == proID { purchased = true }
                if transaction.productID == trialID { receiptDate = transaction.originalPurchaseDate }
            case .unverified(let transaction, _):
                if transaction.productID == proID, purchased != true { purchased = nil }
            }
        }
        return (purchased, receiptDate)
    }
}
