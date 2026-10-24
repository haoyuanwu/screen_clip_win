import Cocoa
import ServiceManagement
import FlutterMacOS
import Carbon
import ScreenCaptureKit
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var statusItem: NSStatusItem?
  private var hotkey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var captureScreen: NSScreen?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  private var capturing = false

  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    title = "定格T"
    minSize = NSSize(width: 440, height: 280)
    delegate = self
    isReleasedWhenClosed = false
    NSApp.setActivationPolicy(.accessory)
    RegisterGeneratedPlugins(registry: controller)
    channel = FlutterMethodChannel(name: "screenclip/desktop", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "dataDirectory":
        do {
          let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          let directory = base.appendingPathComponent("ScreenClip", isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          result(directory.path)
        } catch { result(FlutterError(code: "storage", message: error.localizedDescription, details: nil)) }
      case "launchAtLoginStatus", "setLaunchAtLogin":
        do {
          let service = SMAppService.mainApp
          if call.method == "setLaunchAtLogin" {
            if call.arguments as? Bool == true {
              if service.status == .notRegistered { try service.register() }
            } else if service.status != .notRegistered {
              try service.unregister()
            }
          }
          switch service.status {
          case .enabled: result("enabled")
          case .requiresApproval: result("requiresApproval")
          default: result("disabled")
          }
        } catch { result(FlutterError(code: "startup", message: "开机启动设置失败：\(error.localizedDescription)", details: nil)) }
      case "registerHotkey":
        self.setupStatusItem(); result(self.setupHotkey())
        DispatchQueue.main.async { self.orderOut(nil) }
      case "present": self.present(call.arguments as? String ?? "palette"); result(nil)
      case "dismiss": self.orderOut(nil); self.level = .normal; result(nil)
      case "copied": self.statusItem?.button?.toolTip = "已复制到剪贴板 · Control + Shift + X 再次截图"; result(nil)
      case "capture": self.capture(call.arguments as? String ?? "region", result: result)
      case "copy":
        guard let bytes = call.arguments as? FlutterStandardTypedData, let image = NSImage(data: bytes.data) else { result(FlutterError(code: "image", message: "无法读取图片", details: nil)); return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { result(nil) }
        else { result(FlutterError(code: "clipboard", message: "剪贴板暂不可用，请重试", details: nil)) }
      case "save":
        guard let args = call.arguments as? [String: Any], let bytes = args["bytes"] as? FlutterStandardTypedData else { result(FlutterError(code: "image", message: "图片数据无效", details: nil)); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = args["name"] as? String ?? "定格T.png"
        let previousLevel = self.level; self.level = .normal
        panel.beginSheetModal(for: self) { response in
          self.level = previousLevel
          guard response == .OK, let url = panel.url else { result(nil); return }
          do { try bytes.data.write(to: url, options: .atomic); result(url.path) }
          catch { result(FlutterError(code: "save", message: error.localizedDescription, details: nil)) }
        }
      case "permissions":
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }; result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib(); orderOut(nil)
  }
  private func present(_ panel: String) {
    if panel == "capture", let screen = captureScreen {
      styleMask = [.borderless]; level = .screenSaver; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      setFrame(screen.frame, display: true); NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil); return
    }
    styleMask = [.titled, .closable, .miniaturizable, .resizable]; level = .normal
    let size: NSSize
    switch panel {
    case "settings": size = NSSize(width: 530, height: 590)
    default: size = NSSize(width: 620, height: 280)
    }
    setContentSize(size); center(); NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil)
  }
  private func open(_ panel: String) { channel.invokeMethod("openPanel", arguments: panel) }
  private func request(_ mode: String) { channel.invokeMethod("captureRequested", arguments: mode) }
  private func setupStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "定格T截图"); image?.isTemplate = true
    item.button?.image = image; item.button?.toolTip = "定格T · Control + Shift + X"
    let menu = NSMenu()
    let actions: [(String, Selector)] = [("区域截图    ⌃⇧X", #selector(captureRegion)), ("窗口截图", #selector(captureWindow)), ("全屏截图（主显示器）", #selector(captureScreen)), ("截图工具条", #selector(showPalette)), ("偏好设置…", #selector(showPreferences)), ("退出定格T", #selector(quit))]
    for (index, action) in actions.enumerated() {
      if index == 3 || index == 5 { menu.addItem(.separator()) }
      let entry = NSMenuItem(title: action.0, action: action.1, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
    }
    item.menu = menu; statusItem = item
  }
  private func setupHotkey() -> Bool {
    if hotkey != nil { return true }
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
      guard let context = context else { return OSStatus(eventNotHandledErr) }
      let window = Unmanaged<MainFlutterWindow>.fromOpaque(context).takeUnretainedValue()
      DispatchQueue.main.async { window.request("region") }; return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    guard status == noErr else { return false }
    let id = EventHotKeyID(signature: OSType(0x53434C50), id: 71)
    return RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(controlKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotkey) == noErr
  }
  private func capture(_ mode: String, result: @escaping FlutterResult) {
    guard !capturing else { result(FlutterError(code: "busy", message: "截图正在进行", details: nil)); return }
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      result(FlutterError(code: "permission", message: "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许定格T，然后重新启动应用。", details: nil)); return
    }
    capturing = true
    orderOut(nil)
    Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let mouse = NSEvent.mouseLocation
        let screen = mode == "screen" ? NSScreen.screens.first : NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        guard let screen = screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
          throw NSError(domain: "ScreenClip", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到显示器"])
        }
        self.captureScreen = screen
        let image = try await self.snapshot(SCContentFilter(display: display, excludingWindows: ownWindows))
        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screenTop = top - screen.frame.maxY
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var ranks: [CGWindowID: Int] = [:]
        for (index, info) in ordered.enumerated() {
          if let id = info[kCGWindowNumber as String] as? NSNumber { ranks[id.uint32Value] = index }
        }
        // Keep WindowServer ordering: the first containing window is frontmost.
        let windows = content.windows.sorted { (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max) }.filter { $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }.map { window -> [String: Double] in
          ["x": Double((window.frame.minX - screen.frame.minX) * scaleX), "y": Double((window.frame.minY - screenTop) * scaleY), "width": Double(window.frame.width * scaleX), "height": Double(window.frame.height * scaleY)]
        }
        self.capturing = false
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
          result(FlutterError(code: "capture", message: "截图编码失败", details: nil)); return
        }
        result(["bytes": FlutterStandardTypedData(bytes: data), "windows": windows, "screens": [["x": 0, "y": 0, "width": image.width, "height": image.height]]])
      } catch { self.capturing = false; result(FlutterError(code: "capture", message: error.localizedDescription, details: nil)) }
    }
  }
  private func snapshot(_ filter: SCContentFilter) async throws -> CGImage {
    let config = SCStreamConfiguration()
    config.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
    config.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { channel.invokeMethod("dismissed", arguments: nil); orderOut(nil); return false }
  @objc private func captureRegion() { request("region") }
  @objc private func captureWindow() { request("window") }
  @objc private func captureScreen() { request("screen") }
  @objc private func showPalette() { open("palette") }
  @objc private func showPreferences() { open("settings") }
  @objc private func quit() { channel.invokeMethod("dismissed", arguments: nil); NSApp.terminate(nil) }
  deinit { if let hotkey = hotkey { UnregisterEventHotKey(hotkey) }; if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) } }
}
