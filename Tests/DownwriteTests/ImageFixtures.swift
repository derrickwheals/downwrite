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
}
