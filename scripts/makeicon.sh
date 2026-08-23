#!/usr/bin/env bash
# Render StudyBar's app icon (gradient squircle + graduation cap) and populate the asset catalog.
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="Sources/StudyBar/Resources/Assets.xcassets/AppIcon.appiconset"
MASTER="/tmp/studybar_icon.png"

swift - <<'SWIFT'
import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset = S * 0.085
let rect = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let radius = rect.width * 0.2237
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let colors = [NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 1).cgColor,
              NSColor(srgbRed: 0.46, green: 0.30, blue: 0.90, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
ctx.restoreGState()
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.44, weight: .semibold)
if let sym = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: sym.size)
    sym.draw(in: r); r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let drawRect = NSRect(x: (S - sym.size.width)/2, y: (S - sym.size.height)/2 - S*0.01,
                          width: sym.size.width, height: sym.size.height)
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 0.97)
}
img.unlockFocus()
if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try! png.write(to: URL(fileURLWithPath: "/tmp/studybar_icon.png"))
}
SWIFT

for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px "$MASTER" --out "$ICONSET/icon_$px.png" >/dev/null
done

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom":"mac", "scale":"1x", "size":"16x16",   "filename":"icon_16.png" },
    { "idiom":"mac", "scale":"2x", "size":"16x16",   "filename":"icon_32.png" },
    { "idiom":"mac", "scale":"1x", "size":"32x32",   "filename":"icon_32.png" },
    { "idiom":"mac", "scale":"2x", "size":"32x32",   "filename":"icon_64.png" },
    { "idiom":"mac", "scale":"1x", "size":"128x128", "filename":"icon_128.png" },
    { "idiom":"mac", "scale":"2x", "size":"128x128", "filename":"icon_256.png" },
    { "idiom":"mac", "scale":"1x", "size":"256x256", "filename":"icon_256.png" },
    { "idiom":"mac", "scale":"2x", "size":"256x256", "filename":"icon_512.png" },
    { "idiom":"mac", "scale":"1x", "size":"512x512", "filename":"icon_512.png" },
    { "idiom":"mac", "scale":"2x", "size":"512x512", "filename":"icon_1024.png" }
  ],
  "info" : { "author":"xcode", "version":1 }
}
JSON
echo "Icon generated into $ICONSET"
