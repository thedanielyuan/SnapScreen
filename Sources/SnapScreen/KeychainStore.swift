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
  /// Keychains to use instead of the user's, for the focus test's temporary keychain.
  private let keychains: [SecKeychain]?
  /// Whether the item's keychain is unlocked, replaceable so the self-test needn't lock one.
  private let lockState: ([String: Any]) -> KeychainLock.State

  init(service: String = "com.snapscreen.app", account: String = "anthropic-api-key",
    keychains: [SecKeychain]? = nil,
    lockState: @escaping ([String: Any]) -> KeychainLock.State = { KeychainLock.state(of: $0) }) {
    self.service = service
    self.account = account
    self.keychains = keychains
    self.lockState = lockState
  }

  private var query: [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account]
    if let keychains { query[kSecMatchSearchList as String] = keychains }
    return query
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
    let status = try prompting ? SecItemCopyMatching(item as CFDictionary, &result)
      : KeychainPrompts.disallowed { () -> OSStatus in
        // Turning prompts off doesn't stop macOS from asking to unlock a locked keychain, so the
        // key is read only from a keychain that's known to be unlocked.
        switch lockState(query) {
        case .unlocked: return SecItemCopyMatching(item as CFDictionary, &result)
        case .missing: return errSecItemNotFound
        case .locked, .unknown: return errSecInteractionNotAllowed
        }
      }
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
    if let keychain = keychains?.first {
      item.removeValue(forKey: kSecMatchSearchList as String)
      item[kSecUseKeychain as String] = keychain
    }
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
/// `LAContext` stops it from asking there; SecKeychainSetUserInteractionAllowed, deprecated with
/// the rest of the SecKeychain API, stops it for an item that doesn't trust the app, so it's looked
/// up at run time. It doesn't stop the unlock dialog, which `KeychainLock` avoids. A nonprompting
/// read fails if that control is unavailable or can't disable prompts.
enum KeychainPrompts {
  private typealias GetAllowed = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
  private typealias SetAllowed = @convention(c) (DarwinBoolean) -> OSStatus

  /// Kept separate from the runtime symbols so failure checks never need a real password prompt.
  struct InteractionControl {
    let getAllowed: () -> Bool?
    let setAllowed: (Bool) -> OSStatus
  }

  private static let control: InteractionControl? = {
    guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let get = dlsym(security, "SecKeychainGetUserInteractionAllowed"),
      let set = dlsym(security, "SecKeychainSetUserInteractionAllowed") else { return nil }
    let getAllowed = unsafeBitCast(get, to: GetAllowed.self)
    let setAllowed = unsafeBitCast(set, to: SetAllowed.self)
    return InteractionControl(getAllowed: {
      var allowed: DarwinBoolean = true
      return getAllowed(&allowed) == errSecSuccess ? allowed.boolValue : nil
    }, setAllowed: { setAllowed(DarwinBoolean($0)) })
  }()

  static var canDisallow: Bool { control != nil }

  /// Whether this process may ask now, or nil when that can't be read.
  static var areAllowed: Bool? { control?.getAllowed() }

  static func disallowed<T>(_ body: () -> T) throws -> T {
    try disallowed(using: control, body)
  }

  /// Runs `body` with this process's keychain prompts turned off, then restores the setting. Every
  /// keychain call is on the main thread, so none runs in between. Don't attempt the read unless
  /// prompts are disabled and their prior setting is known, so Settings can still prompt later.
  static func disallowed<T>(using control: InteractionControl?, _ body: () -> T) throws -> T {
    guard let control, let saved = control.getAllowed(), control.setAllowed(false) == errSecSuccess else {
      throw KeychainError(operation: .readWithoutPrompt, status: errSecInteractionNotAllowed)
    }
    defer { _ = control.setAllowed(saved) }
    return body()
  }
}

/// Whether the keychain holding an item is unlocked. On macOS 27, a read with prompts turned off
/// still shows the dialog that unlocks a locked keychain, so a nonprompting read checks this first.
/// Finding the item reads only its attributes, and reading the lock status needs no password, so
/// neither asks. Like the prompt control, the SecKeychain calls are looked up at run time.
enum KeychainLock {
  enum State: Equatable { case unlocked, locked, missing, unknown }

  /// Kept separate from the runtime symbols so the self-test can check each state without locking
  /// a keychain.
  struct Inspection {
    /// The keychain that holds an item.
    let keychain: (AnyObject) -> AnyObject?
    /// A keychain's status flags, or nil when they can't be read.
    let status: (AnyObject) -> UInt32?
  }

  private typealias CopyKeychain = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>) -> OSStatus
  private typealias GetStatus = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt32>) -> OSStatus
  /// SecKeychainStatus's kSecUnlockStateStatus.
  private static let unlockedFlag: UInt32 = 1

  private static let inspection: Inspection? = {
    guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let copy = dlsym(security, "SecKeychainItemCopyKeychain"),
      let get = dlsym(security, "SecKeychainGetStatus") else { return nil }
    let copyKeychain = unsafeBitCast(copy, to: CopyKeychain.self)
    let getStatus = unsafeBitCast(get, to: GetStatus.self)
    return Inspection(keychain: { item in
      var keychain: UnsafeRawPointer?
      guard copyKeychain(Unmanaged.passUnretained(item).toOpaque(), &keychain) == errSecSuccess,
        let keychain else { return nil }
      return Unmanaged<AnyObject>.fromOpaque(keychain).takeRetainedValue()
    }, status: { keychain in
      var status: UInt32 = 0
      return getStatus(Unmanaged.passUnretained(keychain).toOpaque(), &status) == errSecSuccess ? status : nil
    })
  }()

  /// `query` finds the item as a read would. Anything that can't be confirmed is `unknown`, which
  /// a nonprompting read treats as locked.
  static func state(of query: [String: Any], using inspection: Inspection? = inspection) -> State {
    var item = query
    item[kSecReturnRef as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    var reference: CFTypeRef?
    let found = SecItemCopyMatching(item as CFDictionary, &reference)
    if found == errSecItemNotFound { return .missing }
    guard found == errSecSuccess, let reference, let inspection, let keychain = inspection.keychain(reference),
      let status = inspection.status(keychain) else { return .unknown }
    return status & unlockedFlag != 0 ? .unlocked : .locked
  }
}
