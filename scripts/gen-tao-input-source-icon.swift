#!/usr/bin/env swift
// Renders the 韬输入法 input source (menu bar) icon: 「韬」 knocked out of a 22×16 pt
// rounded rectangle, like scripts/gen-input-source-icon.swift but with the system's
// PingFang SC, so it needs no downloaded font.
//   swift scripts/gen-tao-input-source-icon.swift
// Writes Apps/AIME/Resources/AIME.pdf (+ a PNG preview into build/).
import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let width: CGFloat = 22, height: CGFloat = 16, radius: CGFloat = 3.5
let glyphSize: CGFloat = 13

let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, glyphSize, nil)
var character: UniChar = 0x97EC // 韬
var glyph: CGGlyph = 0
guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
      let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("韬 is missing from PingFang SC") }
let ink = outline.boundingBoxOfPath
let centred = outline.copy(using: [CGAffineTransform(translationX: (width - ink.width) / 2 - ink.minX,
                                                    y: (height - ink.height) / 2 - ink.minY)])!
let frame = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
let icon = frame.subtracting(centred, using: .winding)

let pdfURL = root.appendingPathComponent("Apps/AIME/Resources/AIME.pdf")
var box = CGRect(x: 0, y: 0, width: width, height: height)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, [kCGPDFContextCreator: "scripts/gen-tao-input-source-icon.swift"] as CFDictionary)!
pdf.beginPDFPage(nil)
pdf.addPath(icon)
pdf.setFillColor(.black)
pdf.fillPath(using: .evenOdd)
pdf.endPDFPage()
pdf.closePDF()

// 8× PNG preview for review.
let scale: CGFloat = 8
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
ctx.scaleBy(x: scale, y: scale); ctx.addPath(icon); ctx.setFillColor(.black); ctx.fillPath(using: .evenOdd)
let preview = root.appendingPathComponent("build/tao-icon-preview.png")
try rep.representation(using: .png, properties: [:])!.write(to: preview)
print("input source icon written: 韬 in PingFang SC Semibold → \(pdfURL.path)")
