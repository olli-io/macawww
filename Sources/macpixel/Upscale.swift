import Foundation

/// Integer upscale detection (SPEC §6 step 5). Pixel art that is saved at N× is stored at 1×.
/// Decode time only. Pixels are 32-bit, the stride is width × 4.
enum Upscale {
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// The largest N for which each aligned N×N block of the frame has one colour.
    /// N is a divisor of `limit` when `limit` > 0. Returns 1 when there is no upscale.
    static func factor(_ px: UnsafeRawPointer, width w: Int, height h: Int, limit: Int = 0) -> Int {
        let p = px.assumingMemoryBound(to: UInt32.self)
        // N divides all run lengths of equal pixels, along the rows and along the columns.
        var g = limit
        var runs = [Int](repeating: 1, count: w)  // open vertical run of each column
        for y in 0..<h {
            let row = p + y * w
            var run = 1
            for x in 1..<max(1, w) {
                if row[x] == row[x - 1] { run += 1 } else { g = gcd(g, run); run = 1 }
            }
            g = gcd(g, run)
            if y > 0 {
                let up = row - w
                for x in 0..<w {
                    if row[x] == up[x] { runs[x] += 1 } else { g = gcd(g, runs[x]); runs[x] = 1 }
                }
            }
            if g == 1 { return 1 }
        }
        for x in 0..<w { g = gcd(g, runs[x]) }
        return g
    }

    /// True when each aligned n×n block of the frame has one colour.
    static func holds(_ px: UnsafeRawPointer, width w: Int, height h: Int, n: Int) -> Bool {
        guard n > 0, w % n == 0, h % n == 0 else { return false }
        let p = px.assumingMemoryBound(to: UInt32.self)
        for by in stride(from: 0, to: h, by: n) {
            let row = p + by * w
            for bx in stride(from: 0, to: w, by: n) {
                let v = row[bx]
                for i in 1..<n where row[bx + i] != v { return false }
            }
            for i in 1..<n where memcmp(row, row + i * w, w * 4) != 0 { return false }
        }
        return true
    }

    /// Copies one pixel of each n×n block to `dst` (width / n × height / n). No filter, no loss.
    static func shrink(_ px: UnsafeRawPointer, width w: Int, height h: Int, n: Int,
                       to dst: UnsafeMutableRawPointer) {
        let p = px.assumingMemoryBound(to: UInt32.self)
        let d = dst.assumingMemoryBound(to: UInt32.self)
        let dw = w / n, dh = h / n
        for y in 0..<dh {
            let row = p + y * n * w, out = d + y * dw
            for x in 0..<dw { out[x] = row[x * n] }
        }
    }
}
