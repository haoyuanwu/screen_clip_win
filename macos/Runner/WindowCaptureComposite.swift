import CoreGraphics
import Foundation

struct PinTextGlyph {
  let start: Int, end: Int, line: Int
  let box: CGRect
}

struct PinTextSelection {
  var text = ""
  var glyphs: [PinTextGlyph] = []
  var anchor = 0, extent = 0
  var range: NSRange { NSRange(location: min(anchor, extent), length: abs(extent - anchor)) }
  var selected: String {
    let value = text as NSString
    guard range.location + range.length <= value.length else { return "" }
    return value.substring(with: range)
  }
  func boundary(_ p: CGPoint) -> Int {
    var best: PinTextGlyph?, distance = CGFloat.infinity
    for glyph in glyphs {
      let r = glyph.box
      let dy = max(max(r.minY - p.y, p.y - r.maxY), 0)
      let dx = max(max(r.minX - p.x, p.x - r.maxX), 0)
      let score = dy * 1000 + dx
      if score < distance { distance = score; best = glyph }
    }
    guard let glyph = best else { return 0 }
    return p.x < glyph.box.midX ? glyph.start : glyph.end
  }
  func hit(_ p: CGPoint, tolerance: CGSize) -> Bool {
    glyphs.contains { $0.box.insetBy(dx: -tolerance.width, dy: -tolerance.height).contains(p) }
  }
  var highlights: [CGRect] {
    var lines: [Int: CGRect] = [:]
    for glyph in glyphs where glyph.start < range.location + range.length && glyph.end > range.location {
      lines[glyph.line] = lines[glyph.line]?.union(glyph.box) ?? glyph.box
    }
    return Array(lines.values)
  }
}

/// Keep sub-point keyboard movement when WindowServer rounds a Retina warp.
/// A real pointer move resets the accumulator to the newly observed position.
struct CursorPixelNudger {
  private var target: CGPoint?
  private var lastObserved: CGPoint?

  mutating func next(observed: CGPoint, delta: CGPoint, size: CGSize) -> CGPoint {
    let unchanged = lastObserved.map {
      abs($0.x - observed.x) < 0.01 && abs($0.y - observed.y) < 0.01
    } ?? false
    let base = unchanged ? (target ?? observed) : observed
    let next = CGPoint(x: min(max(base.x + delta.x, 0), size.width - 1),
      y: min(max(base.y + delta.y, 0), size.height - 1))
    target = next
    return next
  }

  mutating func didWarp(observed: CGPoint) { lastObserved = observed }
}

/// Places an isolated window at its original screen position. Input coordinates
/// are source pixels with a top-left origin; Quartz drawing uses bottom-left.
enum WindowCaptureComposite {
  static func image(background: CGImage, window: CGImage, pixelRect: CGRect) -> CGImage? {
    guard pixelRect.width > 0, pixelRect.height > 0,
          let context = CGContext(data: nil, width: background.width, height: background.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: background.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(background, in: CGRect(x: 0, y: 0, width: background.width, height: background.height))
    context.interpolationQuality = .high
    context.draw(window, in: CGRect(x: pixelRect.minX,
      y: CGFloat(background.height) - pixelRect.maxY,
      width: pixelRect.width, height: pixelRect.height))
    return context.makeImage()
  }
}
