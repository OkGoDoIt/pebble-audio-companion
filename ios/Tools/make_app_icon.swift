#!/usr/bin/env swift
//
//  make_app_icon.swift — generates the Pebble Audio app icon (1024×1024 PNG).
//
//  Run:  swift ios/Tools/make_app_icon.swift ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
//  The mark is the app's visual signature: the four-state audio waveform (M10 / plan Part 2-A).
//  Brand violet ground; bars in white (transcribed), translucent white (captured), a squat amber
//  marker (missing) and low stubs (quiet). The amber bar is the whole product thesis in one pixel
//  run — loss is always shown, never hidden — and it is the only hue break, so the icon still
//  reads as one confident shape at 40 pt.
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024

// MARK: - Palette (Tokens.swift light anchors)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a
    )
}

let tintTop = rgb(0x7373E4)      // lifted brand violet
let tintBottom = rgb(0x4A4AC4)   // tintPressed
let missing = rgb(0xFF9500)
let white = rgb(0xFFFFFF)
let captured = rgb(0xFFFFFF, 0.55)
let quiet = rgb(0xFFFFFF, 0.34)

// MARK: - The waveform mark
//
// One bar per slot. `h` is the fraction of the mark's height; `kind` picks the ink.
enum Kind { case voice, captured, quiet, missing }
let bars: [(h: CGFloat, kind: Kind)] = [
    (0.34, .voice), (0.58, .voice), (0.86, .voice), (1.00, .voice), (0.70, .voice),
    (0.09, .quiet), (0.09, .quiet),
    (0.36, .missing),
    (0.09, .quiet),
    (0.52, .captured), (0.78, .captured), (0.62, .captured), (0.38, .captured),
]

func ink(_ kind: Kind) -> CGColor {
    switch kind {
    case .voice: white
    case .captured: captured
    case .quiet: quiet
    case .missing: missing
    }
}

// MARK: - Render

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard
    let ctx = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else { fatalError("could not create the bitmap context") }

// Ground: a full-bleed vertical gradient (iOS applies the squircle mask itself).
let gradient = CGGradient(
    colorsSpace: colorSpace, colors: [tintTop, tintBottom] as CFArray, locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: []
)

// Bars: centred, generous margins so the mark survives the squircle crop and 40 pt rendering.
let markWidth = side * 0.72
let markHeight = side * 0.54
let barWidth = markWidth / (CGFloat(bars.count) * 1.52)
let gap = (markWidth - barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
let originX = (side - markWidth) / 2
let centerY = side / 2
let minHeight = barWidth  // a stub is a dot, never a sliver

for (index, bar) in bars.enumerated() {
    let height = max(markHeight * bar.h, minHeight)
    let x = originX + CGFloat(index) * (barWidth + gap)
    let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
    ctx.setFillColor(ink(bar.kind))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                       transform: nil))
    ctx.fillPath()
}

// MARK: - Write

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
)
guard
    let image = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not encode the PNG") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(outPath)") }
print("wrote \(outPath) (\(Int(side))×\(Int(side)))")
