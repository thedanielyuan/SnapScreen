import Foundation
import Security

/// Where Settings keeps the API key, so the self-test can use memory instead.
protocol APIKeyStore: AnyObject {
  /// Whether a key is saved. It looks only at the item's attributes, never the key, so it never
  /// asks for Keychain access.
  var hasKey: Bool { get }
  /// The saved key, or nil when there is none. macOS may ask for your login password first.
  func read() throws -> String?
  /// Like `read`, but fails rather than let macOS ask for your password, which would take the
  /// keyboard from the app you're using. Answers read the key this way; Settings may ask.
  func readWithoutPrompt() throws -> String?
  func save(_ key: String) throws
  /// Removing a key that isn't saved succeeds.
  func remove() throws
}

extension APIKeyStore {
  func readWithoutPrompt() throws -> String? { try read() }
}

struct KeychainError: Error, Equatable {
  enum Operation { case read, readWithoutPrompt, save, remove }
  let operation: Operation
  let status: OSStatus

  var message: String {
    let action: String
    switch operation {
    case .read, .readWithoutPrompt: action = "read the API key from"
    case .save: action = "save the API key to"
    case .remove: action = "remove the API key from"
    }
    // The keychain wanted your password: it's locked, or the key doesn't trust this build yet.
    if operation == .readWithoutPrompt,
      [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled].contains(status) {
      return "Open SnapScreen Settings to allow access to your API key in the Keychain, then Retry."
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

  func read() throws -> String? { try read(prompting: true) }

  func readWithoutPrompt() throws -> String? { try read(prompting: false) }

  private func read(prompting: Bool) throws -> String? {
    var item = query
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = prompting ? SecItemCopyMatching(item as CFDictionary, &result)
      : KeychainPrompts.disallowed { SecItemCopyMatching(item as CFDictionary, &result) }
    let operation: KeychainError.Operation = prompting ? .read : .readWithoutPrompt
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(operation: operation, status: status) }
    guard let data = result as? Data else { throw KeychainError(operation: operation, status: errSecDecode) }
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

/// Whether the login keychain may ask for your password, which it does when an item doesn't trust
/// the app reading it or the keychain is locked. Neither `kSecUseAuthenticationUIFail` nor an
/// `LAContext` stops it from asking there; only SecKeychainSetUserInteractionAllowed, deprecated
/// with the rest of the SecKeychain API, does, so it's looked up at run time. Without it, a read
/// may still ask.
enum KeychainPrompts {
  private typealias GetAllowed = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
  private typealias SetAllowed = @convention(c) (DarwinBoolean) -> OSStatus

  private static let functions: (GetAllowed, SetAllowed)? = {
    guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let get = dlsym(security, "SecKeychainGetUserInteractionAllowed"),
      let set = dlsym(security, "SecKeychainSetUserInteractionAllowed") else { return nil }
    return (unsafeBitCast(get, to: GetAllowed.self), unsafeBitCast(set, to: SetAllowed.self))
  }()

  static var canDisallow: Bool { functions != nil }

  /// Whether this process may ask now, or nil when that can't be read.
  static var areAllowed: Bool? {
    guard let (get, _) = functions else { return nil }
    var allowed: DarwinBoolean = true
    return get(&allowed) == errSecSuccess ? allowed.boolValue : nil
  }

  /// Runs `body` with this process's keychain prompts turned off, then restores the setting. Every
  /// keychain call is on the main thread, so none runs in between.
  static func disallowed<T>(_ body: () -> T) -> T {
    guard let (_, set) = functions else { return body() }
    let saved = areAllowed ?? true
    _ = set(false)
    defer { _ = set(DarwinBoolean(saved)) }
    return body()
  }
}
