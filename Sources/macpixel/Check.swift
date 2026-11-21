import CoreGraphics
import Foundation

/// `macpixel check`: lists the images that are not pixel art (SPEC §4).
/// Runs in the client. No daemon, no cache file.
enum Check {
    static let notPixelArt = "the image is not pixel art"

    /// The integer upscale of the image, as the decoder calculates it (SPEC §6 step 5). 1 = not pixel art.
    static func factor(_ url: URL) throws -> Int {
        let source = try Decoder.Source(url: url)
        var first: CGImage? = try source.image(0)
        let w = first?.width ?? 0, h = first?.height ?? 0
        guard (1...Cache.maxSide).contains(w), (1...Cache.maxSide).contains(h) else {
            throw MCWError.decode("image size \(w)x\(h) not supported")
        }
        let buf = calloc(w * h * 4, 1)
        defer { free(buf) }
        guard let buf, let ctx = FrameEncoder.context(buf, w, h) else {
            throw MCWError.decode("cannot create bitmap context")
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var n = 0  // 0 = no limit
        for i in 0..<source.count where n != 1 {
            try autoreleasepool {
                let img = try first ?? source.image(i)
                first = nil
                ctx.draw(img, in: rect)
                n = Upscale.factor(buf, width: w, height: h, limit: n)
            }
        }
        return n
    }

    /// Nil when the image is pixel art, else the reason.
    static func reason(_ url: URL) -> String? {
        do {
            return try factor(url) > 1 ? nil : notPixelArt
        } catch let e as MCWError {
            if case .decode(let m) = e { return m }
            return e.description
        } catch {
            return error.localizedDescription
        }
    }

    /// The images of `path` that are not pixel art, each with the reason. A file gives only itself.
    static func rejected(_ path: String) -> [(url: URL, reason: String)] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let files = isDirectory(url.path) ? Picker.images(in: url) : [url]
        var out: [(url: URL, reason: String)] = []
        for f in files {
            if let r = autoreleasepool(invoking: { reason(f) }) { out.append((f, r)) }
        }
        return out
    }

    /// Prints one line for each image that is not pixel art. Returns the exit code.
    static func run(_ path: String) -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            eprint("no such file or directory: \(path)")
            return 1
        }
        let bad = rejected(path)
        for b in bad { print("\(b.url.path): \(b.reason)") }
        return bad.isEmpty ? 0 : 1
    }
}
