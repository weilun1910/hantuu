import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Synthetic files for the file viewer's self test, all made here: a PDF, images (PNG, HEIC,
/// GIF), a short video, a tone, RTF, text in several shapes, a binary blob and a symlink.
struct FileViewerFixtures {
    let root: URL
    var code: URL { root.appendingPathComponent("Sources/Parser.swift") }
    var long: URL { root.appendingPathComponent("Sources/Long.swift") }
    var markdown: URL { root.appendingPathComponent("NOTES.md") }
    var svg: URL { root.appendingPathComponent("logo.svg") }
    var csv: URL { root.appendingPathComponent("results.csv") }
    var pdf: URL { root.appendingPathComponent("paper.pdf") }
    var png: URL { root.appendingPathComponent("chart.png") }
    var heic: URL { root.appendingPathComponent("photo.heic") }
    var gif: URL { root.appendingPathComponent("spinner.gif") }
    var video: URL { root.appendingPathComponent("clip.mov") }
    var audio: URL { root.appendingPathComponent("tone.wav") }
    var rtf: URL { root.appendingPathComponent("letter.rtf") }
    var docx: URL { root.appendingPathComponent("report.docx") }
    var blob: URL { root.appendingPathComponent("model.weights") }
    var big: URL { root.appendingPathComponent("build.log") }
    var binaryText: URL { root.appendingPathComponent("dump.txt") }
    var latin1: URL { root.appendingPathComponent("legacy.txt") }
    var crlf: URL { root.appendingPathComponent("windows.txt") }
    var bom: URL { root.appendingPathComponent("bom.txt") }
    var typescript: URL { root.appendingPathComponent("web/app.ts") }
    var folder: URL { root.appendingPathComponent("Sources") }
    var outside: URL { root.appendingPathComponent("elsewhere/real.swift") }
    var link: URL { root.appendingPathComponent("Sources/Linked.swift") }

    static let swiftSource = """
    import Foundation

    /// Splits a line into tokens, skipping runs of whitespace.
    struct Parser {
        let source: String

        func tokens() -> [Substring] {
            source.split(whereSeparator: { $0.isWhitespace })
        }

        func count() -> Int {
            // Counting without building the array would be faster.
            tokens().count
        }
    }

    let sample = Parser(source: "let  x =  42")
    print(sample.tokens(), sample.count())

    """

    static func make(_ root: URL) -> FileViewerFixtures {
        let f = FileViewerFixtures(root: root)
        try? FileManager.default.removeItem(at: root)
        for d in ["Sources", "web", "elsewhere"] { Paths.ensure(root.appendingPathComponent(d)) }
        func write(_ url: URL, _ s: String) { try? Data(s.utf8).write(to: url) }
        write(f.code, swiftSource)
        write(f.long, (1...200).map { "let value\($0) = \($0) // line \($0)" }.joined(separator: "\n") + "\n")
        write(f.markdown, "# Notes\n\nThe parser now skips **runs of whitespace**. See `Sources/Parser.swift`.\n\n- Tokens are substrings\n- Counting is $O(n)$\n")
        write(f.svg, """
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="160" viewBox="0 0 240 160">
          <rect x="20" y="20" width="200" height="120" rx="14" fill="none" stroke="#2f6fd0" stroke-width="6"/>
          <circle cx="120" cy="80" r="30" fill="#e5a23b"/>
        </svg>
        """)
        write(f.csv, "model,tokens,latency_ms,notes\nopus,1820,412,\"long, careful\"\nsonnet,1640,233,balanced\nhaiku,1210,98,fast\n")
        write(f.typescript, "export const answer: number = 42;\n")
        write(f.outside, "let outside = true\n")
        try? FileManager.default.createSymbolicLink(atPath: f.link.path, withDestinationPath: f.outside.path)
        try? Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: f.latin1) // "café" in Latin-1
        write(f.crlf, "first line\r\nsecond line\r\n")
        try? (Data([0xEF, 0xBB, 0xBF]) + Data("with a byte order mark\n".utf8)).write(to: f.bom)
        try? (Data("header\n".utf8) + Data([0, 1, 2, 3, 0]) + Data("tail\n".utf8)).write(to: f.binaryText)
        try? Data((0..<4096).map { UInt8(($0 * 37 + 11) % 256) }).write(to: f.blob)
        try? Data().write(to: f.docx)
        var log = ""
        let line = "2026-11-11T10:00:00Z INFO build step finished in 12ms, nothing to report here at all\n"
        while log.utf8.count < 5_000_000 { log += line }
        write(f.big, log)

        if let png = chartPNG(width: 960, height: 600, bars: [0.42, 0.68, 0.55, 0.81, 0.63]) { try? png.write(to: f.png) }
        if let img = chartImage(width: 800, height: 520, bars: [0.3, 0.5, 0.7]) {
            writeImage(img, to: f.heic, type: "public.heic")
            writeGIF([img, chartImage(width: 800, height: 520, bars: [0.7, 0.5, 0.3]) ?? img], to: f.gif)
        }
        makePDF(f.pdf)
        makeWAV(f.audio)
        makeRTF(f.rtf)
        _ = makeVideo(f.video)
        return f
    }

    // MARK: Images

    static func chartImage(width: Int, height: Int, bars: [CGFloat]) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
        ctx.setLineWidth(1)
        for i in 1...4 {
            let y = h * 0.12 + (h * 0.76) * CGFloat(i) / 4
            ctx.move(to: CGPoint(x: w * 0.08, y: y)); ctx.addLine(to: CGPoint(x: w * 0.94, y: y))
        }
        ctx.strokePath()
        let slot = (w * 0.86) / CGFloat(bars.count)
        for (i, v) in bars.enumerated() {
            let accent = i == bars.count - 2
            ctx.setFillColor(accent ? CGColor(srgbRed: 0.18, green: 0.44, blue: 0.82, alpha: 1) : CGColor(gray: 0.62, alpha: 1))
            let r = CGRect(x: w * 0.08 + slot * CGFloat(i) + slot * 0.22, y: h * 0.12, width: slot * 0.56, height: h * 0.76 * v)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: w * 0.08, y: h * 0.12 - 1.5, width: w * 0.86, height: 1.5))
        return ctx.makeImage()
    }

    static func chartPNG(width: Int, height: Int, bars: [CGFloat]) -> Data? {
        guard let img = chartImage(width: width, height: height, bars: bars) else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func writeImage(_ img: CGImage, to url: URL, type: String) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    static func writeGIF(_ frames: [CGImage], to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    // MARK: PDF, RTF, audio

    static func makePDF(_ url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        let title = NSFont.systemFont(ofSize: 26, weight: .semibold)
        let body = NSFont.systemFont(ofSize: 12.5)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        let pages: [(String, String)] = [
            ("Skipping whitespace", "This note explains why the parser now splits on runs of whitespace instead of single spaces. Tokens are substrings of the source, so nothing is copied until a caller asks for a String.\n\nCounting tokens still builds the array first. A dedicated counter would walk the source once and keep no allocations, which matters for the large files agents tend to produce."),
            ("Next steps", "1. Add a test for tabs and newlines between tokens.\n2. Measure the counter on a 50 MB log.\n3. Update the README with the new behaviour."),
        ]
        for (i, (head, text)) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            let g = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            NSColor.white.setFill()
            box.fill()
            NSAttributedString(string: head, attributes: [.font: title, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
                .draw(in: NSRect(x: 72, y: 660, width: 468, height: 60))
            NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: NSColor(white: 0.2, alpha: 1), .paragraphStyle: para])
                .draw(in: NSRect(x: 72, y: 360, width: 468, height: 280))
            NSAttributedString(string: "\(i + 1)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.gray])
                .draw(at: NSPoint(x: 302, y: 40))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func makeRTF(_ url: URL) {
        let s = NSAttributedString(string: "Dear reader,\n\nThis letter is rich text, previewed by Quick Look.\n",
                                   attributes: [.font: NSFont.systemFont(ofSize: 14)])
        try? s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])?.write(to: url)
    }

    static func makeWAV(_ url: URL) {
        let rate = 22050, seconds = 1
        var samples = Data()
        for i in 0..<(rate * seconds) {
            let v = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8000)
            withUnsafeBytes(of: v.littleEndian) { samples.append(contentsOf: $0) }
        }
        var d = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(UInt32(36 + samples.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(samples.count))
        d.append(samples)
        try? d.write(to: url)
    }

    // MARK: Video

    /// Two seconds of H.264 at 640 by 360: a soft dark gradient with a disc moving across.
    static func makeVideo(_ url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let w = 640, h = 360
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let frames = 30
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let colors = [CGColor(srgbRed: 0.16, green: 0.2, blue: 0.27, alpha: 1), CGColor(srgbRed: 0.42, green: 0.32, blue: 0.3, alpha: 1)] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
                }
                let x = 120 + CGFloat(i) * 13
                ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.78, blue: 0.45, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: x, y: 130, width: 100, height: 100))
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
                ctx.fill(CGRect(x: 0, y: 70, width: w, height: 2))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 15))
        }
        input.markAsFinished()
        var done = false
        writer.finishWriting { done = true }
        let end = Date().addingTimeInterval(10)
        while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return writer.status == .completed
    }
}
