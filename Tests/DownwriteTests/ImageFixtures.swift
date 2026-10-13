import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Images for the paste and drop tests, generated with ImageIO so nothing binary is committed.
enum ImageFixtures {
    /// A `width` × `height` RGBA image: a smooth gradient (small when encoded), or noise (incompressible, so large) when `noise`.
    static func cgImage(width: Int, height: Int, noise: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if noise {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    buffer[i] = UInt8(truncatingIfNeeded: seed >> 33)
                    buffer[i + 1] = UInt8(truncatingIfNeeded: seed >> 41)
                    buffer[i + 2] = UInt8(truncatingIfNeeded: seed >> 49)
                } else {
                    buffer[i] = UInt8(x * 255 / max(1, width - 1))
                    buffer[i + 1] = UInt8(y * 255 / max(1, height - 1))
                    buffer[i + 2] = UInt8((x + y) & 255)
                }
                buffer[i + 3] = 255
            }
        }
        return context.makeImage()!
    }

    /// `image` encoded as `type` (nil when this machine has no encoder for it, e.g. HEIC on some runners).
    static func data(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    static func png(width: Int = 40, height: Int = 30, noise: Bool = false) -> Data {
        data(cgImage(width: width, height: height, noise: noise), as: .png)!
    }

    static func jpeg(width: Int = 40, height: Int = 30, noise: Bool = false, quality: Double = 0.9, properties: [CFString: Any] = [:]) -> Data {
        var all = properties
        all[kCGImageDestinationLossyCompressionQuality] = quality
        return data(cgImage(width: width, height: height, noise: noise), as: .jpeg, properties: all)!
    }

    static func tiff(width: Int = 40, height: Int = 30) -> Data { data(cgImage(width: width, height: height), as: .tiff)! }
    static func bmp(width: Int = 40, height: Int = 30) -> Data { data(cgImage(width: width, height: height), as: .bmp)! }

    /// nil when this machine has no HEIC encoder.
    static func heic(width: Int = 64, height: Int = 48, properties: [CFString: Any] = [:]) -> Data? {
        data(cgImage(width: width, height: height), as: .heic, properties: properties)
    }

    /// An animated GIF of `frames` frames.
    static func gif(width: Int = 60, height: Int = 60, frames: Int = 3) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            let frame = cgImage(width: width + i, height: height)                          // distinct frames
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// A 1 × 1 lossy WebP (ImageIO can read WebP but cannot write it).
    static let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!

    static func svg(padding: Int = 0) -> Data {
        Data(("<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\" fill=\"red\"/>"
              + "<!--" + String(repeating: "x", count: padding) + "--></svg>").utf8)
    }

    /// A one-page PDF.
    static func pdf() -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return out as Data
    }

    /// The EXIF, TIFF and GPS metadata a phone photo carries.
    static let photoMetadata: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "keep me", kCGImagePropertyExifLensMake: "Lensco"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cameraco", kCGImagePropertyTIFFModel: "Model 7"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
    ]

    /// ImageIO's view of `data`: its properties at index 0.
    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func frameCount(of data: Data) -> Int {
        CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
    }

    // MARK: Animated PNG

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return be32(UInt32(body.count)) + typed + be32(crc32(typed))
    }

    /// The (type, body) chunks of a PNG file.
    private static func chunks(of png: Data) -> [(String, [UInt8])] {
        let bytes = Array(png)
        var out: [(String, [UInt8])] = []
        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            out.append((type, Array(bytes[(i + 8)..<(i + 8 + length)])))
            i += 12 + length
        }
        return out
    }

    /// An APNG of `frames` frames of the same size, built chunk by chunk (ImageIO cannot write one): `acTL`, then each frame's
    /// `fcTL` and its image data (`IDAT` for the first, `fdAT` for the rest).
    static func apng(width: Int = 40, height: Int = 30, frames: Int = 3, noise: Bool = false) -> Data {
        let still = chunks(of: png(width: width, height: height, noise: noise))
        let ihdr = still.first { $0.0 == "IHDR" }!.1
        let idat = still.filter { $0.0 == "IDAT" }.flatMap { $0.1 }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", ihdr)
        out += chunk("acTL", be32(UInt32(frames)) + be32(0))
        var sequence: UInt32 = 0
        for frame in 0..<frames {
            let control = be32(sequence) + be32(UInt32(width)) + be32(UInt32(height)) + be32(0) + be32(0) + [0, 10, 0, 100, 0, 0]
            sequence += 1
            out += chunk("fcTL", control)
            if frame == 0 {
                out += chunk("IDAT", idat)
            } else {
                out += chunk("fdAT", be32(sequence) + idat)
                sequence += 1
            }
        }
        out += chunk("IEND", [])
        return Data(out)
    }
}
