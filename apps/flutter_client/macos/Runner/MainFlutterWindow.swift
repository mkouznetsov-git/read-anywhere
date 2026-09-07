import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  private var secureStorageCompatibility: ReadArcSecureStorageCompatibility?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // flutter_secure_storage 9.2.4 / flutter_secure_storage_macos 3.1.3
    // always adds kSecUseDataProtectionKeychain to macOS Keychain queries,
    // even when the Dart option explicitly sets it to false. For an ad-hoc
    // distributed ReadArc build that can route the call through an entitlement
    // path that is not available and leave startup waiting on secure storage.
    // Upstream fixed this in flutter_secure_storage_darwin 0.3.2 by omitting
    // kSecUseDataProtectionKeychain entirely when legacy Keychain is requested.
    // Keep the pinned dependency for now, but install that exact compatibility
    // behavior on the existing plugin channel after generated registration.
    secureStorageCompatibility = ReadArcSecureStorageCompatibility(controller: flutterViewController)

    super.awakeFromNib()
  }
}

private final class ReadArcSecureStorageCompatibility {
  private static let channelName = "plugins.it_nomads.com/flutter_secure_storage"
  private let channel: FlutterMethodChannel

  init(controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "ReadArcSecureStorage", message: "Secure storage compatibility handler is unavailable", details: nil))
        return
      }
      self.handle(call, result: result)
    }
  }

  private struct Request {
    let accountName: String?
    let groupId: String?
    let synchronizable: Bool
    let useDataProtectionKeychain: Bool
    let accessibility: String?
    let key: String?
    let value: String?
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let request = parse(call)
    switch call.method {
    case "read":
      guard let key = request.key else {
        result(parameterError("read requires key parameter"))
        return
      }
      read(key: key, request: request, result: result)
    case "write":
      guard let key = request.key else {
        result(parameterError("write requires key parameter"))
        return
      }
      guard let value = request.value else {
        result(parameterError("write requires value parameter"))
        return
      }
      write(key: key, value: value, request: request, result: result)
    case "delete":
      guard let key = request.key else {
        result(parameterError("delete requires key parameter"))
        return
      }
      delete(key: key, request: request, result: result)
    case "deleteAll":
      deleteAll(request: request, result: result)
    case "readAll":
      readAll(request: request, result: result)
    case "containsKey":
      guard let key = request.key else {
        result(parameterError("containsKey requires key parameter"))
        return
      }
      containsKey(key: key, request: request, result: result)
    case "isProtectedDataAvailable":
      if #available(macOS 12.0, *) {
        result(NSApplication.shared.isProtectedDataAvailable)
      } else {
        result(true)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func parse(_ call: FlutterMethodCall) -> Request {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let options = arguments["options"] as? [String: Any] ?? [:]
    let synchronizable = boolOption(options["synchronizable"], defaultValue: false)
    let useDataProtectionKeychain = boolOption(options["useDataProtectionKeyChain"], defaultValue: true)
    return Request(
      accountName: options["accountName"] as? String,
      groupId: options["groupId"] as? String,
      synchronizable: synchronizable,
      useDataProtectionKeychain: useDataProtectionKeychain,
      accessibility: options["accessibility"] as? String,
      key: arguments["key"] as? String,
      value: arguments["value"] as? String
    )
  }

  private func boolOption(_ raw: Any?, defaultValue: Bool) -> Bool {
    if let value = raw as? Bool { return value }
    if let value = raw as? String { return Bool(value) ?? defaultValue }
    return defaultValue
  }

  private func accessibleAttribute(_ accessibility: String?) -> CFString {
    switch accessibility {
    case "passcode":
      return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    case "unlocked_this_device":
      return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    case "first_unlock":
      return kSecAttrAccessibleAfterFirstUnlock
    case "first_unlock_this_device":
      return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    case "unlocked", .none:
      return kSecAttrAccessibleWhenUnlocked
    default:
      return kSecAttrAccessibleWhenUnlocked
    }
  }

  private func baseQuery(
    key: String?,
    request: Request,
    returnData: Bool? = nil
  ) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccessible: accessibleAttribute(request.accessibility),
      kSecAttrSynchronizable: request.synchronizable,
    ]

    // Critical compatibility rule: false means OMIT the attribute. Passing
    // kSecUseDataProtectionKeychain=false still selects an entitlement-sensitive
    // path in affected macOS/plugin combinations.
    if #available(macOS 10.15, *), request.useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain] = true
    }
    if let key { query[kSecAttrAccount] = key }
    if let groupId = request.groupId { query[kSecAttrAccessGroup] = groupId }
    if let accountName = request.accountName { query[kSecAttrService] = accountName }
    if let returnData { query[kSecReturnData] = returnData }
    return query
  }

  private func read(key: String, request: Request, result: @escaping FlutterResult) {
    let query = baseQuery(key: key, request: request, returnData: true)
    var ref: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    if status == errSecItemNotFound {
      result(nil)
      return
    }
    guard status == errSecSuccess else {
      result(securityError(status))
      return
    }
    guard let data = ref as? Data else {
      result(nil)
      return
    }
    result(String(data: data, encoding: .utf8))
  }

  private func write(key: String, value: String, request: Request, result: @escaping FlutterResult) {
    var lookup = baseQuery(key: key, request: request)
    let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, nil)
    let data = value.data(using: .utf8) ?? Data()

    if lookupStatus == errSecSuccess {
      var update: [CFString: Any] = [
        kSecValueData: data,
        kSecAttrAccessible: accessibleAttribute(request.accessibility),
        kSecAttrSynchronizable: request.synchronizable,
      ]
      if #available(macOS 10.15, *), request.useDataProtectionKeychain {
        update[kSecUseDataProtectionKeychain] = true
      }
      let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
      finish(status: status, value: nil, result: result)
      return
    }

    guard lookupStatus == errSecItemNotFound else {
      result(securityError(lookupStatus))
      return
    }

    lookup[kSecValueData] = data
    let status = SecItemAdd(lookup as CFDictionary, nil)
    finish(status: status, value: nil, result: result)
  }

  private func delete(key: String, request: Request, result: @escaping FlutterResult) {
    let query = baseQuery(key: key, request: request)
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound {
      result(nil)
      return
    }
    finish(status: status, value: nil, result: result)
  }

  private func deleteAll(request: Request, result: @escaping FlutterResult) {
    let query = baseQuery(key: nil, request: request)
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound {
      result(nil)
      return
    }
    finish(status: status, value: nil, result: result)
  }

  private func containsKey(key: String, request: Request, result: @escaping FlutterResult) {
    let query = baseQuery(key: key, request: request, returnData: false)
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      result(true)
    case errSecItemNotFound:
      result(false)
    default:
      result(securityError(status))
    }
  }

  private func readAll(request: Request, result: @escaping FlutterResult) {
    var query = baseQuery(key: nil, request: request, returnData: true)
    query[kSecMatchLimit] = kSecMatchLimitAll
    query[kSecReturnAttributes] = true

    var ref: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    if status == errSecItemNotFound {
      result([String: String]())
      return
    }
    guard status == errSecSuccess else {
      result(securityError(status))
      return
    }

    var values = [String: String]()
    if let items = ref as? NSArray {
      for case let item as NSDictionary in items {
        guard
          let key = item[kSecAttrAccount] as? String,
          let data = item[kSecValueData] as? Data
        else { continue }
        values[key] = String(data: data, encoding: .utf8) ?? ""
      }
    }
    result(values)
  }

  private func finish(status: OSStatus, value: Any?, result: @escaping FlutterResult) {
    if status == errSecSuccess {
      result(value)
    } else {
      result(securityError(status))
    }
  }

  private func parameterError(_ message: String) -> FlutterError {
    FlutterError(code: "Missing Parameter", message: message, details: nil)
  }

  private func securityError(_ status: OSStatus) -> FlutterError {
    let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown security result code"
    return FlutterError(
      code: "Unexpected security result code",
      message: "Code: \(status), Message: \(message)",
      details: status
    )
  }
}
