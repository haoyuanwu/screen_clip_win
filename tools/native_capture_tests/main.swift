import CoreGraphics
import Foundation

func image(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
  let pixel = [color.0, color.1, color.2, color.3]
  let bytes = Array(repeating: pixel, count: width * height).flatMap { $0 }
  let provider = CGDataProvider(data: Data(bytes) as CFData)!
  return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
  let data = image.dataProvider!.data!
  let bytes = CFDataGetBytePtr(data)!
  let offset = y * image.bytesPerRow + x * 4
  return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
}

let background = image(width: 12, height: 10, color: (255, 255, 255, 255))
if #available(macOS 14.0, *) {
  // Independent-window captures must fill the entire pixel surface at both
  // nominal and Retina desktop scales, including mixed-display selections.
  for scale in [CGFloat(1), 1.5, 2] {
    let config = WindowCaptureComposite.configuration(
      pixelSize: CGSize(width: 601 * scale, height: 399 * scale))
    assert(config.scalesToFit, "Window content must upscale to the desktop pixel scale")
    assert(config.destinationRect == CGRect(x: 0, y: 0, width: config.width, height: config.height))
    assert(config.width == Int((601 * scale).rounded()))
    assert(config.height == Int((399 * scale).rounded()))
    assert(config.ignoreShadowsSingleWindow && !config.showsCursor)
  }
  print("Independent-window output fills 1x, fractional and Retina surfaces")
}
let red = image(width: 4, height: 2, color: (255, 0, 0, 255))
let first = WindowCaptureComposite.image(background: background, window: red,
  pixelRect: CGRect(x: 2, y: 1, width: 4, height: 2))!
assert(first.width == 12 && first.height == 10)
assert(pixel(first, 3, 1) == [255, 0, 0, 255], "Window must appear at top-left source coordinates")
assert(pixel(first, 3, 7) == [255, 255, 255, 255], "Window must not be vertically mirrored")
assert(pixel(first, 1, 1) == [255, 255, 255, 255])
let clipped = WindowCaptureComposite.image(background: background, window: red,
  pixelRect: CGRect(x: -2, y: 8, width: 4, height: 4))!
assert(pixel(clipped, 0, 9) == [255, 0, 0, 255])
assert(pixel(clipped, 3, 9) == [255, 255, 255, 255])
let transparent = image(width: 2, height: 2, color: (0, 0, 0, 0))
let preserved = WindowCaptureComposite.image(background: background, window: transparent,
  pixelRect: CGRect(x: 0, y: 0, width: 2, height: 2))!
assert(pixel(preserved, 0, 0) == [255, 255, 255, 255])
assert(WindowCaptureComposite.image(background: background, window: red, pixelRect: .zero) == nil)
print("Native window composition: dimensions, top-left coordinates, clipping and transparency passed")

// Simulate a 2x Retina display whose pointer rounds down to whole points.
for delta in [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1)] {
  var nudger = CursorPixelNudger()
  var observed = CGPoint(x: 100, y: 100)
  for step in 1...6 {
    let target = nudger.next(observed: observed, delta: delta, size: CGSize(width: 800, height: 600))
    assert(target.x == 100 + delta.x * CGFloat(step))
    assert(target.y == 100 + delta.y * CGFloat(step))
    observed = CGPoint(x: floor(target.x / 2) * 2, y: floor(target.y / 2) * 2)
    nudger.didWarp(observed: observed)
  }
  let moved = nudger.next(observed: CGPoint(x: 250, y: 300), delta: delta, size: CGSize(width: 800, height: 600))
  assert(moved == CGPoint(x: 250 + delta.x, y: 300 + delta.y))
}
print("Retina WASD: four directions accumulate correctly and manual mouse movement resets the origin")

var pin = PinTextSelection()
pin.text = "Hello\n文字"
pin.glyphs = [
  PinTextGlyph(start: 0, end: 5, line: 0, box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.1)),
  PinTextGlyph(start: 6, end: 7, line: 1, box: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.1)),
  PinTextGlyph(start: 7, end: 8, line: 1, box: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.1))
]
assert(pin.hit(CGPoint(x: 0.15, y: 0.55), tolerance: .zero))
assert(!pin.hit(CGPoint(x: 0.8, y: 0.8), tolerance: .zero))
pin.anchor = pin.boundary(CGPoint(x: 0.31, y: 0.55))
pin.extent = pin.boundary(CGPoint(x: 0.09, y: 0.15))
assert(pin.selected == "Hello\n文字")
assert(pin.highlights.count == 2)
pin.anchor = 6; pin.extent = 7
assert(pin.selected == "文")
print("Pinned OCR: reverse cross-line selection, UTF-16 copying and normalized hit testing passed")

let mainFrame = CGRect(x: 0, y: 0, width: 100, height: 80)
let leftFrame = CGRect(x: -80, y: 20, width: 80, height: 60)
let aboveFrame = CGRect(x: 20, y: 80, width: 50, height: 40)
let desktop = DesktopCaptureGeometry(frames: [mainFrame, leftFrame, aboveFrame], scale: 2)
assert(!DesktopCaptureGeometry.matchesViewport(CGSize(width: 100, height: 80), contentView: desktop.frame.size),
  "A texture laid out on just the primary display must not replace the desktop snapshot")
assert(!DesktopCaptureGeometry.matchesViewport(.zero, contentView: desktop.frame.size))
assert(DesktopCaptureGeometry.matchesViewport(desktop.frame.size, contentView: desktop.frame.size))
assert(desktop.frame == CGRect(x: -80, y: 0, width: 180, height: 120))
assert(desktop.pixelRect(mainFrame) == CGRect(x: 160, y: 80, width: 200, height: 160))
assert(desktop.pixelRect(leftFrame) == CGRect(x: 0, y: 80, width: 160, height: 120))
assert(desktop.pixelRect(aboveFrame) == CGRect(x: 200, y: 0, width: 100, height: 80))
let combined = desktop.composite([
  (mainFrame, image(width: 200, height: 160, color: (255, 255, 255, 255))),
  (leftFrame, image(width: 80, height: 60, color: (255, 0, 0, 255))),
  (aboveFrame, image(width: 100, height: 80, color: (0, 255, 0, 255)))
])!
assert(combined.width == 360 && combined.height == 240)
assert(pixel(combined, 10, 90) == [255, 0, 0, 255])
assert(pixel(combined, 220, 10) == [0, 255, 0, 255])
assert(pixel(combined, 170, 100) == [255, 255, 255, 255])
let clamped = desktop.nearestPixel(CGPoint(x: 10, y: 10), screens: [mainFrame, leftFrame, aboveFrame])
assert(clamped == CGPoint(x: 10, y: 80))
print("Multi-display eyedropper: negative origins, screens above primary, mixed scales, colors and gap clamping passed")
