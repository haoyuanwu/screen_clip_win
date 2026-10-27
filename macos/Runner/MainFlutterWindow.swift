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
  private var captureDesktop: DesktopCaptureGeometry?
  private var cursorNudger = CursorPixelNudger()
  private var pins: [PinnedImagePanel] = []
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  private var capturing = false
  private var captureFrameReady = false
  private var captureCover: CaptureSnapshotCover?
  private var capturePresentationEpoch = 0
  private var captureMirrorSession = 0
  private var captureMirrors: [CGDirectDisplayID: CaptureMirrorPanel] = [:]
  private var capturePointerMonitor: Any?
  private var replacedInstances: [NSRunningApplication] = []
  private var debugReplacementObserver: NSObjectProtocol?

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    // AppKit normally keeps a window on one display. A capture surface must
    // retain the desktop union, including the area above/left of the main screen.
    if captureDesktop != nil, styleMask.contains(.borderless), level == .screenSaver { return frameRect }
    return super.constrainFrameRect(frameRect, to: screen)
  }

  override func awakeFromNib() {
    let current = NSRunningApplication.current
    #if DEBUG
    if let id = Bundle.main.bundleIdentifier {
      let name = Notification.Name("\(id).replaceDebugInstance")
      debugReplacementObserver = DistributedNotificationCenter.default().addObserver(
        forName: name, object: nil, queue: .main) { notification in
          guard let sender = notification.object as? String,
                sender != String(ProcessInfo.processInfo.processIdentifier) else { return }
          // Sandboxed apps cannot reliably terminate a sibling process. Let the
          // old debug process retire itself without waiting on a stale Dart VM.
          exit(EXIT_SUCCESS)
        }
      DistributedNotificationCenter.default().postNotificationName(name,
        object: String(current.processIdentifier), userInfo: nil, deliverImmediately: true)
    }
    #endif
    if let id = Bundle.main.bundleIdentifier,
       let existing = NSWorkspace.shared.runningApplications.first(where: {
         $0.bundleIdentifier == id && $0.processIdentifier != current.processIdentifier && !$0.isTerminated &&
           ($0.launchDate ?? .distantPast) <= (current.launchDate ?? .distantFuture)
       }) {
      #if DEBUG
      // Flutter run must attach to this new engine. Reusing the old process
      // makes the new process exit before the debug service can connect.
      replacedInstances = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == id && $0.processIdentifier != current.processIdentifier && !$0.isTerminated
      }
      replacedInstances.forEach { $0.terminate() }
      #else
      existing.activate(options: [])
      NSApp.terminate(nil)
      return
      #endif
    }
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
        Task { @MainActor in
          // Give replaced processes time to unregister their Carbon hotkeys.
          for _ in 0..<40 {
            if self.replacedInstances.allSatisfy({ $0.isTerminated }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
          }
          #if DEBUG
          // A prior Flutter engine may no longer answer its graceful quit
          // handshake. A debug rerun replaces that stale process as well.
          self.replacedInstances.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
          for _ in 0..<10 {
            if self.replacedInstances.allSatisfy({ $0.isTerminated }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
          }
          #endif
          self.replacedInstances = []
          result(self.setupHotkey())
          self.orderOut(nil)
        }
      case "registerColorHotkey": result(self.setupColorHotkey())
      case "present": self.present(call.arguments as? String ?? "palette"); result(nil)
      case "dismiss": self.clearCaptureMirrors(); self.clearCaptureCover(); self.captureFrameReady = false; self.orderOut(nil); self.captureBackground = nil; self.level = .normal; result(nil)
      case "captureMirrorLayouts":
        result(["session": self.captureMirrorSession, "screens": self.captureMirrors.map { id, panel -> [String: Any] in
          let frame = panel.targetFrame, desktop = self.captureDesktop!.frame
          return ["displayId": Int(id), "x": frame.minX - desktop.minX,
            "y": desktop.maxY - frame.maxY, "width": frame.width, "height": frame.height,
            "scale": panel.pixelScale]
        }])
      case "updateCaptureMirror":
        if let args = call.arguments as? [String: Any],
           self.captureFrameReady,
           let session = args["session"] as? Int, session == self.captureMirrorSession,
           let id = args["displayId"] as? Int, let panel = self.captureMirrors[CGDirectDisplayID(id)],
           let bytes = args["bytes"] as? FlutterStandardTypedData,
           let width = args["width"] as? Int, let height = args["height"] as? Int,
           width > 0, height > 0, width <= 20000, height <= 20000,
           bytes.data.count == width * height * 4,
           let provider = CGDataProvider(data: bytes.data as CFData),
           let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
          if args["overlay"] as? Bool == true,
             let left = args["left"] as? Double, let top = args["top"] as? Double,
             let logicalWidth = args["logicalWidth"] as? Double,
             let logicalHeight = args["logicalHeight"] as? Double {
            for other in self.captureMirrors.values where other !== panel { other.clearOverlay() }
            panel.showOverlay(image, rect: CGRect(x: left, y: top, width: logicalWidth, height: logicalHeight))
          } else {
            panel.show(image)
          }
        }
        result(nil)
      case "captureFrameReady":
        guard let args = call.arguments as? [String: Double],
              let width = args["width"], let height = args["height"],
              DesktopCaptureGeometry.matchesViewport(CGSize(width: width, height: height), contentView: self.contentView?.bounds.size ?? .zero),
              self.isVisible, self.styleMask.contains(.borderless), self.captureDesktop != nil else {
          result(false); return
        }
        let firstFrame = !self.captureFrameReady
        self.captureFrameReady = true
        if firstFrame, let desktop = self.captureDesktop, !self.captureMirrors.isEmpty {
          let p = NSEvent.mouseLocation
          self.channel.invokeMethod("capturePointer", arguments: [
            "x": p.x - desktop.frame.minX, "y": desktop.frame.maxY - p.y,
            "buttons": 0, "time": ProcessInfo.processInfo.systemUptime,
            "type": "pointer", "scrollX": 0, "scrollY": 0])
        }
        let epoch = self.capturePresentationEpoch
        // The Dart paint callback precedes rasterization. Keep the native
        // snapshot for one display interval rather than exposing an old texture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
          guard let self, self.capturePresentationEpoch == epoch else { return }
          self.clearCaptureCover()
        }
        result(true)
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
        let captureFrame = self.captureDesktop?.frame ?? screen.frame
        let scaleX = CGFloat(image.width) / captureFrame.width
        let scaleY = CGFloat(image.height) / captureFrame.height
        let screenTop = (NSScreen.screens.first?.frame.maxY ?? 0) - captureFrame.maxY
        func observedPixel() -> CGPoint {
          let current = CGEvent(source: nil)?.location ?? CGPoint(x: NSEvent.mouseLocation.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - NSEvent.mouseLocation.y)
          return CGPoint(x: (current.x - captureFrame.minX) * scaleX,
            y: (current.y - screenTop) * scaleY)
        }
        let currentCocoa = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(currentCocoa) }) ?? screen
        let step = self.captureDesktop == nil ? 1 : scaleX / activeScreen.backingScaleFactor
        var point = self.cursorNudger.next(observed: observedPixel(), delta: CGPoint(x: CGFloat(dx) * step, y: CGFloat(dy) * step),
          size: CGSize(width: image.width, height: image.height))
        if let desktop = self.captureDesktop {
          let clamped = desktop.nearestPixel(point, screens: NSScreen.screens.map { $0.frame })
          if clamped != point { self.cursorNudger = CursorPixelNudger(); point = clamped }
        }
        guard CGWarpMouseCursorPosition(CGPoint(x: captureFrame.minX + point.x / scaleX, y: screenTop + point.y / scaleY)) == .success else {
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
        let desktopFrame = self.captureDesktop?.frame ?? screen.frame
        let scale = desktopFrame.width / self.capturePixelWidth
        let source = NSRect(x: desktopFrame.minX + x * scale,
                            y: desktopFrame.maxY - (y + height) * scale,
                            width: width * scale, height: height * scale)
        let targetScreen = NSScreen.screens.max { a, b in
          let ra = a.frame.intersection(source), rb = b.frame.intersection(source)
          return max(0, ra.width * ra.height) < max(0, rb.width * rb.height)
        } ?? screen
        let pin = PinnedImagePanel(image: image, source: source, screen: targetScreen,
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
        self.captureMirrors.values.forEach { $0.level = .normal }
        panel.beginSheetModal(for: self) { response in
          self.level = previousLevel
          self.captureMirrors.values.forEach { $0.level = previousLevel }
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
        self.captureMirrors.values.forEach { $0.level = .normal }
        if NSWorkspace.shared.open(url) { result(nil) }
        else { self.level = previousLevel; self.captureMirrors.values.forEach { $0.level = previousLevel }; result(FlutterError(code: "url", message: "无法打开浏览器，请重试", details: nil)) }
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
      clearCaptureMirrors()
      clearCaptureCover()
      captureDesktop = nil
      captureBackground = nil; captureWindows = []; capturedScreen = nil
      styleMask = [.borderless]; level = .floating; minSize = .zero
      isOpaque = false; backgroundColor = .clear; hasShadow = false
      (contentViewController as? FlutterViewController)?.backgroundColor = .clear
      collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let mouse = NSEvent.mouseLocation
      let work = (NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
      setFrame(CGRect(x: min(max(mouse.x + 16, work.minX), work.maxX - 300), y: min(max(mouse.y - 330, work.minY), work.maxY - 320), width: 300, height: 320), display: true)
      NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil); return
    }
    isOpaque = true; backgroundColor = .windowBackgroundColor; hasShadow = true
    (contentViewController as? FlutterViewController)?.backgroundColor = .windowBackgroundColor
    minSize = NSSize(width: 440, height: 280)
    if panel == "capture", let screen = capturedScreen {
      animationBehavior = .none
      acceptsMouseMovedEvents = true
      styleMask = [.borderless]; level = .screenSaver; collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
      setFrame(captureDesktop?.frame ?? screen.frame, display: false)
      prepareCaptureMirrors()
      if !captureFrameReady, let image = captureBackground, let view = contentView {
        clearCaptureCover()
        let cover = CaptureSnapshotCover(frame: view.bounds)
        cover.image = NSImage(cgImage: image, size: view.bounds.size)
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        view.addSubview(cover, positioned: .above, relativeTo: nil)
        captureCover = cover
      }
      // Show the correctly positioned frozen desktop first. A hidden Flutter
      // window can stop producing frames, so waiting to show it deadlocks.
      NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil)
      // Activation/Space changes can reposition a newly shown borderless window.
      // Reapply its desktop origin after ordering, rather than shifting the image.
      setFrame(captureDesktop?.frame ?? screen.frame, display: true)
      makeFirstResponder(contentViewController?.view)
      contentView?.layoutSubtreeIfNeeded()
      return
    }
    clearCaptureCover()
    clearCaptureMirrors()
    animationBehavior = .default
    styleMask = [.titled, .closable, .miniaturizable, .resizable]; level = .normal
    let size: NSSize
    switch panel {
    case "settings": size = NSSize(width: 530, height: 590)
    default: size = NSSize(width: 620, height: 280)
    }
    setContentSize(size); center(); NSApp.activate(ignoringOtherApps: true); makeKeyAndOrderFront(nil)
  }
  private func clearCaptureCover() {
    capturePresentationEpoch += 1
    captureCover?.removeFromSuperview()
    captureCover = nil
  }
  private func clearCaptureMirrors() {
    captureMirrorSession += 1
    if let monitor = capturePointerMonitor { NSEvent.removeMonitor(monitor) }
    capturePointerMonitor = nil
    captureMirrors.values.forEach { $0.orderOut(nil) }
    captureMirrors = [:]
  }
  private func prepareCaptureMirrors() {
    guard captureMirrors.isEmpty, let desktop = captureDesktop, let image = captureBackground else { return }
    let screens = NSScreen.screens
    // Never guess which display AppKit assigns the union window to: that can
    // change with the trigger display and Space. Every display gets a local panel.
    for screen in screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let crop = image.cropping(to: desktop.pixelRect(screen.frame)) else { continue }
      let panel = CaptureMirrorPanel(screen: screen, image: crop)
      captureMirrors[number.uint32Value] = panel
    }
    if capturePointerMonitor == nil, !captureMirrors.isEmpty {
      let events: NSEvent.EventTypeMask = [.mouseMoved, .mouseEntered, .mouseExited,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
        .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        .keyDown, .keyUp, .flagsChanged]
      capturePointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
        guard let self, self.isVisible, self.level == .screenSaver else { return event }
        if [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
          // Preserve Flutter's normal keyboard handling, then wake the backing
          // scene if the display-local panels made the engine consider it hidden.
          DispatchQueue.main.async { [weak self] in self?.channel.invokeMethod("captureWake", arguments: nil) }
          return event
        }
        guard event.window == nil || event.window === self || self.captureMirrors.values.contains(where: { event.window === $0 }) else { return event }
        self.forwardCapturePointer(event)
        return nil
      }
    }
  }
  private func forwardCapturePointer(_ event: NSEvent) {
    guard let desktop = captureDesktop else { return }
    let p = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    var buttons = Int(NSEvent.pressedMouseButtons)
    switch event.type {
    case .leftMouseDragged: buttons |= 1
    case .rightMouseDragged: buttons |= 2
    case .leftMouseDown: buttons |= 1
    case .leftMouseUp: buttons &= ~1
    case .rightMouseDown: buttons |= 2
    case .rightMouseUp: buttons &= ~2
    default: break
    }
    channel.invokeMethod("capturePointer", arguments: [
      "x": p.x - desktop.frame.minX, "y": desktop.frame.maxY - p.y,
      "buttons": buttons, "time": event.timestamp,
      "type": event.type == .scrollWheel ? "scroll" : "pointer",
      "scrollX": event.type == .scrollWheel ? -event.scrollingDeltaX : 0,
      "scrollY": event.type == .scrollWheel ? -event.scrollingDeltaY : 0])
  }
  func windowDidMove(_ notification: Notification) {
    guard isVisible, level == .screenSaver, styleMask.contains(.borderless),
          let desktop = captureDesktop, frame != desktop.frame else { return }
    // With separate display Spaces, AppKit may asynchronously add the active
    // screen's origin after orderFront, even though setFrame reported success.
    // Correct the actual move notification; fixing it before ordering is too early.
    setFrame(desktop.frame, display: true)
  }
  private func open(_ panel: String) { channel.invokeMethod("openPanel", arguments: panel) }
  private func request(_ mode: String) { channel.invokeMethod("captureRequested", arguments: mode) }
  private func setupStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    // The resident app relies on this entry point even while its window is
    // hidden. Do not opt into Command-drag removal or quit-on-removal.
    item.behavior = []
    item.isVisible = true
    let image = NSImage(systemSymbolName: "crop", accessibilityDescription: "定格T截图"); image?.isTemplate = true
    item.button?.image = image; item.button?.toolTip = "定格T · Control + Shift + X"
    let menu = NSMenu()
    let actions: [(String, Selector)] = [("区域截图    ⌃⇧X", #selector(captureRegion)), ("屏幕取色    ⌃⇧C", #selector(captureColor)), ("窗口截图", #selector(captureWindow)), ("全屏截图（全部显示器）", #selector(captureScreen)), ("截图工具条", #selector(showPalette)), ("偏好设置…", #selector(showPreferences)), ("退出定格T", #selector(quit))]
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
        let desktopFrame = self.captureDesktop?.frame ?? screen.frame
        let scaleX = CGFloat(background.width) / desktopFrame.width
        let scaleY = CGFloat(background.height) / desktopFrame.height
        let screenTop = (NSScreen.screens.first?.frame.maxY ?? 0) - desktopFrame.maxY
        let rect = CGRect(x: (selectedWindow.frame.minX - desktopFrame.minX) * scaleX,
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
    capturing = true
    captureFrameReady = false
    cursorNudger = CursorPixelNudger()
    // ScreenCaptureKit excludes our windows, so leave the current UI stable
    // while preparing the snapshot instead of exposing a 200ms empty desktop.
    Task { @MainActor in
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var snapshots: [(CGRect, CGImage)] = []
        var scale: CGFloat = 1
        for screen in NSScreen.screens {
          guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
          // Exclude the application as a whole: high-level capture panels may
          // not appear in the shareable window list on every display/Space.
          let filter = ownApps.isEmpty
            ? SCContentFilter(display: display, excludingWindows: ownWindows)
            : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
          let image = try await self.snapshot(filter)
          snapshots.append((screen.frame, image))
          scale = max(scale, CGFloat(image.width) / screen.frame.width)
        }
        guard !snapshots.isEmpty else { throw NSError(domain: "ScreenClip", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可截图的显示器"]) }
        let desktop = DesktopCaptureGeometry(frames: snapshots.map { $0.0 }, scale: scale)
        guard let image = desktop.composite(snapshots) else {
          throw NSError(domain: "ScreenClip", code: 2, userInfo: [NSLocalizedDescriptionKey: "多屏截图创建失败"])
        }
        var payload: [String: Any] = [:]
        if mode == "color", let pixels = image.dataProvider?.data, let base = CFDataGetBytePtr(pixels) {
          var rgba = Data(capacity: image.width * image.height * 4)
          for row in 0..<image.height {
            rgba.append(base.advanced(by: row * image.bytesPerRow), count: image.width * 4)
          }
          payload = ["pixels": FlutterStandardTypedData(bytes: rgba), "width": image.width, "height": image.height]
        } else if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
          payload["bytes"] = FlutterStandardTypedData(bytes: data)
        } else {
          throw NSError(domain: "ScreenClip", code: 2, userInfo: [NSLocalizedDescriptionKey: "截图编码失败"])
        }
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var ranks: [CGWindowID: Int] = [:]
        for (index, info) in ordered.enumerated() {
          if let id = info[kCGWindowNumber as String] as? NSNumber { ranks[id.uint32Value] = index }
        }
        let candidates = content.windows.sorted { (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max) }.filter {
          $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 &&
          $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let desktopTop = top - desktop.frame.maxY
        let windows = candidates.map { window -> [String: Double] in
          ["x": Double((window.frame.minX - desktop.frame.minX) * scale),
           "y": Double((window.frame.minY - desktopTop) * scale),
           "width": Double(window.frame.width * scale), "height": Double(window.frame.height * scale)]
        }
        let screens = snapshots.map { entry -> [String: Double] in
          let rect = desktop.pixelRect(entry.0)
          return ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        self.clearCaptureMirrors()
        self.captureDesktop = desktop
        self.capturedScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        self.captureBackground = image; self.capturePixelWidth = CGFloat(image.width); self.captureWindows = mode == "color" ? [] : candidates
        self.capturing = false
        // The next presentation uses a native snapshot while Flutter resumes.
        self.orderOut(nil)
        payload["windows"] = mode == "color" ? [] : windows
        payload["screens"] = screens
        result(payload)
      } catch {
        self.capturing = false
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
          result(FlutterError(code: "permission", message: "当前应用未获准录制屏幕，请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中确认授权后重试。", details: nil))
        } else {
          result(FlutterError(code: "capture", message: error.localizedDescription, details: nil))
        }
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
  func windowShouldClose(_ sender: NSWindow) -> Bool { channel.invokeMethod("dismissed", arguments: nil); clearCaptureMirrors(); clearCaptureCover(); orderOut(nil); captureBackground = nil; return false }
  @objc private func captureColor() { request("color") }
  @objc private func captureRegion() { request("region") }
  @objc private func captureWindow() { request("window") }
  @objc private func captureScreen() { request("screen") }
  @objc private func showPalette() { open("palette") }
  @objc private func showPreferences() { open("settings") }
  @objc private func quit() { captureBackground = nil; channel.invokeMethod("dismissed", arguments: nil); NSApp.terminate(nil) }
  deinit { if let colorHotkey = colorHotkey { UnregisterEventHotKey(colorHotkey) }; if let hotkey = hotkey { UnregisterEventHotKey(hotkey) }; if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) } }
}

/// The cover never takes input away from the editor while its first frame loads.
private class CaptureSnapshotCover: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A display-local surface avoids the single-Space clipping of a desktop-sized
/// window. Its pixels and input both use the one Flutter editor session.
private class CaptureMirrorPanel: NSPanel, NSWindowDelegate {
  let targetFrame: CGRect
  let pixelScale: CGFloat
  private let picture = CaptureMirrorView()
  private let overlay = CaptureSnapshotCover()
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  init(screen: NSScreen, image: CGImage) {
    targetFrame = screen.frame
    pixelScale = screen.backingScaleFactor
    super.init(contentRect: NSRect(origin: .zero, size: screen.frame.size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isReleasedWhenClosed = false; delegate = self; animationBehavior = .none
    level = .screenSaver; collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    hidesOnDeactivate = false; acceptsMouseMovedEvents = true; hasShadow = false
    // Keep the underlying editor considered visible while these panels draw it.
    isOpaque = false; backgroundColor = .clear
    picture.imageScaling = .scaleAxesIndependently
    contentView = picture
    overlay.imageScaling = .scaleAxesIndependently
    overlay.isHidden = true
    picture.addSubview(overlay)
    show(image)
    setFrame(targetFrame, display: true)
    orderFrontRegardless()
  }
  func show(_ image: CGImage) {
    clearOverlay()
    picture.image = NSImage(cgImage: image, size: targetFrame.size)
  }
  func clearOverlay() { overlay.isHidden = true; overlay.image = nil }
  func showOverlay(_ image: CGImage, rect: CGRect) {
    overlay.frame = CGRect(x: rect.minX, y: targetFrame.height - rect.maxY,
      width: rect.width, height: rect.height)
    overlay.image = NSImage(cgImage: image, size: rect.size)
    overlay.isHidden = false
  }
  func windowDidMove(_ notification: Notification) {
    if frame != targetFrame { setFrame(targetFrame, display: true) }
  }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private class CaptureMirrorView: NSImageView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func updateTrackingAreas() {
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(NSTrackingArea(rect: .zero,
      options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil))
    super.updateTrackingAreas()
  }
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
