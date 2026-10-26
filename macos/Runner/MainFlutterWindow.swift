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
  private var colorHotkey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var capturedScreen: NSScreen?
  private var capturePixelWidth: CGFloat = 1
  private var captureWindows: [SCWindow] = []
  private var captureBackground: CGImage?
  private var cursorNudger = CursorPixelNudger()
  private var pins: [PinnedImagePanel] = []
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
        result(self.setupHotkey())
        DispatchQueue.main.async { self.orderOut(nil) }
      case "registerColorHotkey": result(self.setupColorHotkey())
      case "present": self.present(call.arguments as? String ?? "palette"); result(nil)
      case "dismiss": self.orderOut(nil); self.captureBackground = nil; self.level = .normal; result(nil)
      case "copied": self.statusItem?.button?.toolTip = "已复制到剪贴板 · Control + Shift + X 再次截图"; result(nil)
      case "capture": self.capture(call.arguments as? String ?? "region", result: result)
      case "focusCaptureWindow":
        guard let index = call.arguments as? Int else { result(FlutterError(code: "window", message: "窗口索引无效", details: nil)); return }
        self.focusCaptureWindow(index, result: result)
      case "nudgeCursor":
        guard let args = call.arguments as? [String: Any],
              let dx = args["dx"] as? Int, let dy = args["dy"] as? Int,
              abs(dx) <= 10, abs(dy) <= 10,
              let screen = self.capturedScreen, let image = self.captureBackground,
              self.isVisible, self.styleMask.contains(.borderless) else {
          result(FlutterError(code: "cursor", message: "当前无法微调截图光标", details: nil)); return
        }
        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height
        let screenTop = (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.maxY
        func observedPixel() -> CGPoint {
          let current = CGEvent(source: nil)?.location ?? CGPoint(x: NSEvent.mouseLocation.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - NSEvent.mouseLocation.y)
          return CGPoint(x: (current.x - screen.frame.minX) * scaleX,
            y: (current.y - screenTop) * scaleY)
        }
        let point = self.cursorNudger.next(observed: observedPixel(), delta: CGPoint(x: dx, y: dy),
          size: CGSize(width: image.width, height: image.height))
        guard CGWarpMouseCursorPosition(CGPoint(x: screen.frame.minX + point.x / scaleX, y: screenTop + point.y / scaleY)) == .success else {
          self.cursorNudger = CursorPixelNudger()
          result(FlutterError(code: "cursor", message: "光标微调失败，请重试", details: nil)); return
        }
        self.cursorNudger.didWarp(observed: observedPixel())
        result(["x": Double(point.x), "y": Double(point.y)])
      case "pin":
        guard let args = call.arguments as? [String: Any],
              let bytes = args["bytes"] as? FlutterStandardTypedData,
              let image = NSImage(data: bytes.data), let screen = self.capturedScreen,
              let x = args["x"] as? Double, let y = args["y"] as? Double,
              let width = args["width"] as? Double, let height = args["height"] as? Double else {
          result(FlutterError(code: "pin", message: "图片数据无效", details: nil)); return
        }
        let scale = screen.frame.width / self.capturePixelWidth
        let source = NSRect(x: screen.frame.minX + x * scale,
                            y: screen.frame.maxY - (y + height) * scale,
                            width: width * scale, height: height * scale)
        let pin = PinnedImagePanel(image: image, source: source, screen: screen,
          animate: (args["animate"] as? Bool ?? true) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        pin.onClose = { [weak self, weak pin] in self?.pins.removeAll { $0 === pin } }
        self.pins.append(pin); result(nil)
        self.channel.invokeMethod("pinCreated", arguments: ["id": pin.ocrId, "bytes": bytes])
      case "pinOcrResult":
        if let args = call.arguments as? [String: Any], let id = args["id"] as? String,
           let pin = self.pins.first(where: { $0.ocrId == id }) {
          (pin.contentView as? PinnedImageView)?.setOcr(args)
        }
        result(nil)
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
      case "openBrowser":
        guard let value = call.arguments as? String, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
          result(FlutterError(code: "url", message: "二维码内容不是网页链接", details: nil)); return
        }
        let previousLevel = self.level
        self.level = .normal
        if NSWorkspace.shared.open(url) { result(nil) }
        else { self.level = previousLevel; result(FlutterError(code: "url", message: "无法打开浏览器，请重试", details: nil)) }
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
    setupStatusItem()
    // A resident app never shows its window at launch, so viewWillAppear
    // cannot start the Flutter engine for us.
    if !controller.engine.run(withEntrypoint: nil) {
      NSLog("ScreenClip: failed to start the Flutter engine")
    }
    orderOut(nil)
  }
  private func present(_ panel: String) {
    if panel == "color" {
      captureBackground = nil; captureWindows = []; capturedScreen = nil
      styleMask = [.borderless]; level = .floating; minSize = .zero
      collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let mouse = NSEvent.mouseLocation
      let work = (NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
      setFrame(CGRect(x: min(max(mouse.x + 16, work.minX), work.maxX - 300), y: min(max(mouse.y - 330, work.minY), work.maxY - 320), width: 300, height: 320), display: true)
      NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil); return
    }
    minSize = NSSize(width: 440, height: 280)
    if panel == "capture", let screen = capturedScreen {
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
    let actions: [(String, Selector)] = [("区域截图    ⌃⇧X", #selector(captureRegion)), ("屏幕取色    ⌃⇧C", #selector(captureColor)), ("窗口截图", #selector(captureWindow)), ("全屏截图（主显示器）", #selector(captureScreen)), ("截图工具条", #selector(showPalette)), ("偏好设置…", #selector(showPreferences)), ("退出定格T", #selector(quit))]
    for (index, action) in actions.enumerated() {
      if index == 4 || index == 6 { menu.addItem(.separator()) }
      let entry = NSMenuItem(title: action.0, action: action.1, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
    }
    item.menu = menu; statusItem = item
  }
  private func ensureHotkeyHandler() -> Bool {
    if eventHandler != nil { return true }
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
      guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
      let window = Unmanaged<MainFlutterWindow>.fromOpaque(context).takeUnretainedValue()
      let mode = id.id == 72 ? "color" : "region"
      DispatchQueue.main.async { window.request(mode) }; return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler) == noErr
  }
  private func setupHotkey() -> Bool {
    if hotkey != nil { return true }
    guard ensureHotkeyHandler() else { return false }
    let id = EventHotKeyID(signature: OSType(0x53434C50), id: 71)
    return RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(controlKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotkey) == noErr
  }
  private func setupColorHotkey() -> Bool {
    if colorHotkey != nil { return true }
    guard ensureHotkeyHandler() else { return false }
    let id = EventHotKeyID(signature: OSType(0x53434C50), id: 72)
    return RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | shiftKey), id, GetApplicationEventTarget(), 0, &colorHotkey) == noErr
  }
  private func focusCaptureWindow(_ index: Int, result: @escaping FlutterResult) {
    guard !capturing, let screen = capturedScreen, let background = captureBackground,
          index >= -1, index < captureWindows.count else {
      result(FlutterError(code: "window", message: "智能选区已失效，请重新截图", details: nil)); return
    }
    guard CGPreflightScreenCaptureAccess() else {
      result(FlutterError(code: "permission", message: "请在系统设置中允许屏幕录制后重新截图", details: nil)); return
    }
    if index < 0 {
      guard let data = NSBitmapImageRep(cgImage: background).representation(using: .png, properties: [:]) else {
        result(FlutterError(code: "capture", message: "截图编码失败", details: nil)); return
      }
      result(["bytes": FlutterStandardTypedData(bytes: data)]); return
    }
    let selectedWindow = captureWindows[index]
    capturing = true
    Task { @MainActor in
      defer { self.capturing = false }
      do {
        let scaleX = CGFloat(background.width) / screen.frame.width
        let scaleY = CGFloat(background.height) / screen.frame.height
        let screenTop = (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.maxY
        let rect = CGRect(x: (selectedWindow.frame.minX - screen.frame.minX) * scaleX,
          y: (selectedWindow.frame.minY - screenTop) * scaleY,
          width: selectedWindow.frame.width * scaleX, height: selectedWindow.frame.height * scaleY)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(rect.width.rounded()))
        config.height = max(1, Int(rect.height.rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let windowImage = try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: selectedWindow), configuration: config)
        guard let image = WindowCaptureComposite.image(background: background, window: windowImage, pixelRect: rect),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
          throw NSError(domain: "ScreenClip", code: 2, userInfo: [NSLocalizedDescriptionKey: "窗口画面合成失败"])
        }
        result(["bytes": FlutterStandardTypedData(bytes: data)])
      } catch {
        // Preserve the original selection and screen pixels on capture failure.
        result(FlutterError(code: "window", message: "独立抓取窗口失败，可继续使用原截图或重新框选：\(error.localizedDescription)", details: nil))
      }
    }
  }
  private func capture(_ mode: String, result: @escaping FlutterResult) {
    guard !capturing else { result(FlutterError(code: "busy", message: "截图正在进行", details: nil)); return }
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      result(FlutterError(code: "permission", message: "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许定格T，然后重新启动应用。", details: nil)); return
    }
    capturing = true
    captureBackground = nil
    cursorNudger = CursorPixelNudger()
    orderOut(nil)
    Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let mouse = NSEvent.mouseLocation
        let screen = (mode == "screen" ? NSScreen.screens.first : NSScreen.screens.first(where: { $0.frame.contains(mouse) }))
        guard let screen = screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
          throw NSError(domain: "ScreenClip", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到显示器"])
        }
        self.capturedScreen = screen
        let image = try await self.snapshot(SCContentFilter(display: display, excludingWindows: ownWindows))
        self.capturePixelWidth = CGFloat(image.width)
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
        let candidates = content.windows.sorted { (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max) }.filter { $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
        self.captureWindows = candidates
        self.captureBackground = image
        let windows = candidates.map { window -> [String: Double] in
          ["x": Double((window.frame.minX - screen.frame.minX) * scaleX), "y": Double((window.frame.minY - screenTop) * scaleY), "width": Double(window.frame.width * scaleX), "height": Double(window.frame.height * scaleY)]
        }
        self.capturing = false
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
          result(FlutterError(code: "capture", message: "截图编码失败", details: nil)); return
        }
        result(["bytes": FlutterStandardTypedData(bytes: data), "windows": windows, "screens": [["x": 0, "y": 0, "width": image.width, "height": image.height]]])
      } catch {
        self.capturing = false
        result(FlutterError(code: "capture", message: error.localizedDescription, details: nil))
      }
    }
  }
  private func snapshot(_ filter: SCContentFilter) async throws -> CGImage {
    let config = SCStreamConfiguration()
    config.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
    config.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { channel.invokeMethod("dismissed", arguments: nil); orderOut(nil); captureBackground = nil; return false }
  @objc private func captureColor() { request("color") }
  @objc private func captureRegion() { request("region") }
  @objc private func captureWindow() { request("window") }
  @objc private func captureScreen() { request("screen") }
  @objc private func showPalette() { open("palette") }
  @objc private func showPreferences() { open("settings") }
  @objc private func quit() { captureBackground = nil; channel.invokeMethod("dismissed", arguments: nil); NSApp.terminate(nil) }
  deinit { if let colorHotkey = colorHotkey { UnregisterEventHotKey(colorHotkey) }; if let hotkey = hotkey { UnregisterEventHotKey(hotkey) }; if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) } }
}

// Session-only image panels. No screenshot files or history are created.
private class PinnedImagePanel: NSPanel, NSWindowDelegate {
  let ocrId = UUID().uuidString
  var onClose: (() -> Void)?
  let pinnedImage: NSImage
  override var canBecomeKey: Bool { true }
  init(image: NSImage, source: NSRect, screen: NSScreen, animate: Bool) {
    pinnedImage = image
    let work = screen.visibleFrame.insetBy(dx: 8, dy: 8)
    let factor = min(1, min(work.width * 0.6 / source.width, work.height * 0.6 / source.height))
    let size = NSSize(width: max(1, source.width * factor), height: max(1, source.height * factor))
    let destination = NSRect(x: min(max(source.minX + 12, work.minX), work.maxX - size.width),
                             y: min(max(source.minY + 12, work.minY), work.maxY - size.height), width: size.width, height: size.height)
    let origin = source
    super.init(contentRect: animate ? origin : destination, styleMask: [.borderless], backing: .buffered, defer: false)
    title = "定格T · 图钉暂存"; isReleasedWhenClosed = false; delegate = self
    level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    backgroundColor = .clear; isOpaque = false; hasShadow = true; hidesOnDeactivate = false
    contentView = PinnedImageView(frame: NSRect(origin: .zero, size: frame.size), image: image)
    alphaValue = animate ? 0.88 : 1; orderFrontRegardless()
    if animate {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.24
        animator().setFrame(destination, display: true); animator().alphaValue = 1
      }
    }
  }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func copyImage() {
    NSPasteboard.general.clearContents(); _ = NSPasteboard.general.writeObjects([pinnedImage])
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 || event.keyCode == 51 { close() }
    else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
      if (contentView as? PinnedImageView)?.copySelectedText() != true { copyImage() }
    }
    else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
      (contentView as? PinnedImageView)?.selectAllText()
    }
    else { super.keyDown(with: event) }
  }
}

private class PinnedImageView: NSView {
  let image: NSImage
  private let header = NSVisualEffectView()
  private let label = NSTextField(labelWithString: "定格T")
  private let copyButton = NSButton()
  private let textButton = NSButton()
  private let closeButton = NSButton()
  private var ocr = PinTextSelection()
  private var selectingText = false
  private var ocrStatus = "识别文字中…"
  private var reveal: CGFloat = 0
  private var revealTimer: Timer?
  override var acceptsFirstResponder: Bool { true }
  private var hoverArea: NSTrackingArea?
  private var headerVisible = false
  override var isFlipped: Bool { true }
  init(frame: NSRect, image: NSImage) {
    self.image = image
    super.init(frame: frame)
    autoresizingMask = [.width, .height]
    wantsLayer = true
    header.material = .hudWindow
    header.blendingMode = .withinWindow
    header.state = .active
    header.appearance = NSAppearance(named: .vibrantDark)
    header.alphaValue = 0
    header.isHidden = true
    addSubview(header)
    label.stringValue = ocrStatus
    textButton.isEnabled = false
    label.font = NSFont.systemFont(ofSize: 11)
    label.textColor = .white
    header.addSubview(label)
    for (button, symbol, title, action) in [
      (copyButton, "doc.on.doc", "复制图片", #selector(copyPin)),
      (textButton, "text.cursor", "复制选中文字（无选中时复制全部）", #selector(copyTextPin)),
      (closeButton, "xmark", "关闭图钉", #selector(closePin))
    ] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      button.imagePosition = .imageOnly
      button.isBordered = false
      button.contentTintColor = .white
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.target = self
      button.action = action
      header.addSubview(button)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(34, bounds.height))
    label.frame = NSRect(x: 10, y: 9, width: max(0, bounds.width - 124), height: 16)
    label.isHidden = bounds.width < 170
    textButton.frame = NSRect(x: max(0, bounds.width - 108), y: 0, width: 36, height: 34)
    copyButton.frame = NSRect(x: max(0, bounds.width - 72), y: 0, width: 36, height: 34)
    closeButton.frame = NSRect(x: max(0, bounds.width - 36), y: 0, width: 36, height: 34)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea = hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  private func showHeader(_ visible: Bool) {
    guard visible != headerVisible else { return }
    headerVisible = visible
    if visible { header.isHidden = false }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (visible ? 0.16 : 0.10)
      header.animator().alphaValue = visible ? 1 : 0
    }, completionHandler: { [weak self] in
      guard let self = self, !self.headerVisible else { return }
      self.header.isHidden = true
    })
  }
  override func mouseEntered(with event: NSEvent) { showHeader(true) }
  override func mouseExited(with event: NSEvent) { showHeader(false) }
  @objc private func copyPin() { (window as? PinnedImagePanel)?.copyImage() }
  @objc private func copyTextPin() {
    if ocr.range.length == 0 { selectAllText() }
    _ = copySelectedText()
  }
  func selectAllText() {
    guard !ocr.glyphs.isEmpty else { return }
    ocr.anchor = 0; ocr.extent = (ocr.text as NSString).length
    label.stringValue = "已全选文字"; needsDisplay = true
  }
  func copySelectedText() -> Bool {
    let text = ocr.selected
    guard !text.isEmpty else { return false }
    NSPasteboard.general.clearContents()
    let success = NSPasteboard.general.setString(text, forType: .string)
    label.stringValue = success ? "文字已复制" : "复制失败，请重试"
    return true
  }
  func setOcr(_ args: [String: Any]) {
    ocr.text = args["text"] as? String ?? ""
    ocr.glyphs = (args["glyphs"] as? [[String: Any]] ?? []).compactMap { item in
      guard let start = item["start"] as? Int, let end = item["end"] as? Int, let line = item["line"] as? Int,
            let x = item["x"] as? Double, let y = item["y"] as? Double,
            let width = item["width"] as? Double, let height = item["height"] as? Double,
            start >= 0, end > start, end <= (ocr.text as NSString).length, width > 0, height > 0 else { return nil }
      return PinTextGlyph(start: start, end: end, line: line, box: CGRect(x: x, y: y, width: width, height: height))
    }
    let status = args["status"] as? String ?? "error"
    ocrStatus = status == "ready" ? "拖选文字 · ⌘C 复制" : status == "empty" ? "未识别到文字" : "文字识别失败"
    label.stringValue = ocrStatus; textButton.isEnabled = !ocr.glyphs.isEmpty
    textButton.toolTip = ocr.glyphs.isEmpty ? ocrStatus : "复制选中文字（无选中时复制全部）"
    window?.invalidateCursorRects(for: self)
    if !ocr.glyphs.isEmpty {
      reveal = 1
      let started = Date()
      revealTimer?.invalidate()
      revealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
        guard let self = self else { timer.invalidate(); return }
        let elapsed = Date().timeIntervalSince(started)
        self.reveal = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? (elapsed < 1.4 ? 1 : 0) : CGFloat(max(0, min(1, (1.4 - elapsed) / 0.6)))
        self.needsDisplay = true
        if elapsed >= 1.4 { timer.invalidate(); self.revealTimer = nil }
      }
    }
    needsDisplay = true
  }
  private func normalized(_ event: NSEvent) -> CGPoint {
    let p = convert(event.locationInWindow, from: nil)
    return CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height))
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    for glyph in ocr.glyphs {
      let box = CGRect(x: glyph.box.minX * bounds.width, y: glyph.box.minY * bounds.height, width: glyph.box.width * bounds.width, height: glyph.box.height * bounds.height)
      addCursorRect(box, cursor: .iBeam)
    }
  }
  @objc private func closePin() { window?.close() }
  override func draw(_ dirtyRect: NSRect) {
    image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let boxes = reveal > 0 && ocr.range.length == 0 ? ocr.glyphs.map { $0.box } : ocr.highlights
    (reveal > 0 && ocr.range.length == 0 ? NSColor.systemYellow.withAlphaComponent(0.18 * reveal) : NSColor.systemTeal.withAlphaComponent(0.3)).setFill()
    for r in boxes {
      NSBezierPath(roundedRect: CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height), xRadius: 2, yRadius: 2).fill()
    }
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard let panel = window as? PinnedImagePanel else { return }
    let p = normalized(event)
    if !event.modifierFlags.contains(.option), ocr.hit(p, tolerance: CGSize(width: 3 / max(1, bounds.width), height: 3 / max(1, bounds.height))) {
      panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(self)
      selectingText = true; reveal = 0; revealTimer?.invalidate()
      ocr.anchor = ocr.boundary(p); ocr.extent = ocr.anchor; needsDisplay = true
      return
    }
    ocr.anchor = 0; ocr.extent = 0; needsDisplay = true
    panel.performDrag(with: event)
  }
  override func mouseDragged(with event: NSEvent) {
    if selectingText { ocr.extent = ocr.boundary(normalized(event)); needsDisplay = true }
  }
  override func mouseUp(with event: NSEvent) {
    if selectingText { ocr.extent = ocr.boundary(normalized(event)); selectingText = false; needsDisplay = true }
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
      if !copySelectedText() { (window as? PinnedImagePanel)?.copyImage() }
    } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
      selectAllText()
    } else if event.keyCode == 53 || event.keyCode == 51 { window?.close() }
    else { super.keyDown(with: event) }
  }
  deinit { revealTimer?.invalidate() }
  override func rightMouseUp(with event: NSEvent) { window?.close() }
  override func scrollWheel(with event: NSEvent) {
    guard let panel = window, let work = panel.screen?.visibleFrame.insetBy(dx: 8, dy: 8) else { return }
    let ratio = image.size.height / image.size.width
    let maxWidth = min(work.width, work.height / ratio)
    let width = min(maxWidth, max(min(110, maxWidth), panel.frame.width * (event.scrollingDeltaY > 0 ? 1.06 : 0.94)))
    let height = width * ratio
    let x = min(max(panel.frame.minX, work.minX), work.maxX - width)
    let y = min(max(panel.frame.minY, work.minY), work.maxY - height)
    panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
  }
}
