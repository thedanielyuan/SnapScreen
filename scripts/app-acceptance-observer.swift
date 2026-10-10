// Watches, for the standalone app's acceptance round (scripts/app-acceptance.mjs), what Chrome's
// page can't see: SnapScreen's windows, which app is frontmost, password and permission prompts,
// and pasteboard changes. It prints one JSON object per line and exits when its input closes.
// Metadata only: never window titles or contents, and never what's on the pasteboard.
import AppKit

let watched = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.snapscreen.app"
// Processes that show Keychain password dialogs and privacy prompts.
let promptOwners: Set<String> = ["SecurityAgent", "UserNotificationCenter", "universalAccessAuthWarn",
  "CoreServicesUIAgent", "System Settings"]

func emit(_ type: String, _ fields: [String: Any] = [:]) {
  var value = fields
  value["type"] = type
  value["at"] = (Date().timeIntervalSince1970 * 1000).rounded()
  guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func key(_ value: Any) -> String {
  (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

func describe(_ application: NSRunningApplication?) -> [String: Any] {
  guard let application = application else { return [:] }
  return ["bundleId": application.bundleIdentifier ?? "", "pid": Int(application.processIdentifier)]
}

/// Active displays in global coordinates, which window bounds and Chrome's window positions use.
func displays() -> [[String: Any]] {
  var count: UInt32 = 0
  CGGetActiveDisplayList(0, nil, &count)
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  CGGetActiveDisplayList(count, &ids, &count)
  return ids.map { id in
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    return ["id": Int(id), "x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height,
      "pixelWidth": mode?.pixelWidth ?? 0, "pixelHeight": mode?.pixelHeight ?? 0]
  }
}

var lastPids = ""
var lastWindows = ""
var lastPrompts = ""
var lastPasteboard = NSPasteboard.general.changeCount

func poll() {
  let pids = NSRunningApplication.runningApplications(withBundleIdentifier: watched).map { Int($0.processIdentifier) }.sorted()
  if key(pids) != lastPids {
    lastPids = key(pids)
    emit("app", ["pids": pids])
  }
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
  var windows: [[String: Any]] = []
  var prompts: [String: Int] = [:]
  for entry in list {
    let owner = entry[kCGWindowOwnerPID as String] as? Int ?? 0
    if pids.contains(owner) {
      let bounds = entry[kCGWindowBounds as String] as? [String: Double] ?? [:]
      windows.append(["id": entry[kCGWindowNumber as String] as? Int ?? 0, "pid": owner,
        "layer": entry[kCGWindowLayer as String] as? Int ?? 0, "alpha": entry[kCGWindowAlpha as String] as? Double ?? 1,
        "x": bounds["X"] ?? 0, "y": bounds["Y"] ?? 0, "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0])
    } else if let name = entry[kCGWindowOwnerName as String] as? String, promptOwners.contains(name) {
      prompts[name, default: 0] += 1
    }
  }
  if key(windows) != lastWindows {
    lastWindows = key(windows)
    emit("windows", ["windows": windows])
  }
  if key(prompts) != lastPrompts {
    lastPrompts = key(prompts)
    emit("prompts", ["owners": prompts])
  }
  let changeCount = NSPasteboard.general.changeCount
  if changeCount != lastPasteboard {
    lastPasteboard = changeCount
    // The kinds of data only, such as public.utf8-plain-text.
    emit("pasteboard", ["changeCount": changeCount, "types": NSPasteboard.general.types?.map(\.rawValue) ?? []])
  }
}

NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
  object: nil, queue: .main) { note in
  emit("frontmost", describe(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication))
}
FileHandle.standardInput.readabilityHandler = { handle in
  if handle.availableData.isEmpty { exit(0) }
}

let pointer = CGEvent(source: nil)?.location ?? .zero
emit("ready", ["displays": displays(), "frontmost": describe(NSWorkspace.shared.frontmostApplication),
  "pointer": ["x": pointer.x, "y": pointer.y], "watched": watched])
poll()
let timer = Timer(timeInterval: 0.04, repeats: true) { _ in poll() }
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
