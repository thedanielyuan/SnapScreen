import Foundation
import Security

/// Where Settings keeps the API key, so the self-test can use memory instead.
protocol APIKeyStore: AnyObject {
  /// Whether a key is saved. It looks only at the item's attributes, never the key, so it never
  /// asks for Keychain access.
  var hasKey: Bool { get }
  /// The saved key, or nil when there is none.
  func read() throws -> String?
  func save(_ key: String) throws
  /// Removing a key that isn't saved succeeds.
  func remove() throws
}

struct KeychainError: Error, Equatable {
  enum Operation { case read, save, remove }
  let operation: Operation
  let status: OSStatus

  var message: String {
    let action: String
    switch operation {
    case .read: action = "read the API key from"
    case .save: action = "save the API key to"
    case .remove: action = "remove the API key from"
    }
    if status == errSecUserCanceled || status == errSecAuthFailed {
      return "Couldn't \(action) your Keychain because access was denied."
    }
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    return "Couldn't \(action) your Keychain: \(detail)"
  }
}

/// The API key, kept in the login keychain as a generic password. The item trusts the app that
/// created it. macOS recognizes a rebuilt app as that app only when it's signed by the same Apple
/// team, so scripts/build-app.sh signs with an Apple Development certificate; any other build asks
/// for the login password before it can read the key.
final class KeychainStore: APIKeyStore {
  let service: String
  let account: String

  init(service: String = "com.snapscreen.app", account: String = "anthropic-api-key") {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  var hasKey: Bool {
    var item = query
    item[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    return SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess
  }

  func read() throws -> String? {
    var item = query
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(operation: .read, status: status) }
    guard let data = result as? Data else { throw KeychainError(operation: .read, status: errSecDecode) }
    return String(decoding: data, as: UTF8.self)
  }

  func save(_ key: String) throws {
    let data = Data(key.utf8)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw KeychainError(operation: .save, status: status) }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "SnapScreen API key"
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(operation: .save, status: added) }
  }

  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(operation: .remove, status: status)
    }
  }
}
