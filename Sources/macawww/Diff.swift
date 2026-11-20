import Foundation

/// Tile diff and rect merge (SPEC §6 steps 6–8).
enum Diff {
    static let tile = 32
    static let maxRects = 8

    /// Marks changed tiles in `grid` (cols × rows). Returns the count of changed tiles.
    static func tiles(prev: UnsafeRawPointer, cur: UnsafeRawPointer, width: Int, height: Int,
                      grid: inout [Bool]) -> Int {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        let stride = width * 4
        var dirty = 0
        for ty in 0..<rows {
            let y0 = ty * tile, y1 = min(y0 + tile, height)
            for tx in 0..<cols {
                let x0 = tx * tile * 4, n = (min((tx + 1) * tile, width) - tx * tile) * 4
                var d = false
                var y = y0
                while y < y1 {
                    if memcmp(prev + y * stride + x0, cur + y * stride + x0, n) != 0 { d = true; break }
                    y += 1
                }
                grid[ty * cols + tx] = d
                if d { dirty += 1 }
            }
        }
        return dirty
    }

    /// Changed tiles → at most `maxRects` pixel rects.
    static func merge(grid: [Bool], width: Int, height: Int) -> [Rect] {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        // Row runs, then vertical merge of runs with the same x and width.
        var rects: [Rect] = []
        var open: [Int: Int] = [:]
        for ty in 0..<rows {
            var next: [Int: Int] = [:]
            var tx = 0
            while tx < cols {
                guard grid[ty * cols + tx] else { tx += 1; continue }
                let s = tx
                while tx < cols && grid[ty * cols + tx] { tx += 1 }
                let key = s << 16 | (tx - s)
                if let i = open[key] {
                    rects[i].h += 1
                    next[key] = i
                } else {
                    rects.append(Rect(x: s, y: ty, w: tx - s, h: 1))
                    next[key] = rects.count - 1
                }
            }
            open = next
        }
        // Too many rects for the pair merge: one bounding box per band of tile rows.
        if rects.count > 64 {
            rects = []
            let bh = (rows + 31) / 32
            var by = 0
            while by < rows {
                let y1 = min(by + bh, rows)
                var box: Rect?
                for ty in by..<y1 {
                    for tx in 0..<cols where grid[ty * cols + tx] {
                        let t = Rect(x: tx, y: ty, w: 1, h: 1)
                        box = box?.union(t) ?? t
                    }
                }
                if let box { rects.append(box) }
                by = y1
            }
        }
        // Merge the pair with the smallest bounding box until ≤ maxRects.
        while rects.count > maxRects {
            var bi = 0, bj = 1, best = Int.max
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    let a = rects[i].union(rects[j]).area
                    if a < best { best = a; bi = i; bj = j }
                }
            }
            rects[bi] = rects[bi].union(rects[bj])
            rects.remove(at: bj)
        }
        return rects.map {
            Rect(x: $0.x * tile, y: $0.y * tile,
                 w: min(($0.x + $0.w) * tile, width) - $0.x * tile,
                 h: min(($0.y + $0.h) * tile, height) - $0.y * tile)
        }
    }
}
