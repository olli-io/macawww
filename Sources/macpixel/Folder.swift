import Foundation

/// The image files of a directory (SPEC §4): the file list, `check` and rotations.
enum Folder {
    static let extensions: Set<String> = ["gif", "png", "jpg", "jpeg"]

    /// Image files in `dir`, in Finder name order. Hidden files and directories are not included.
    static func images(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { !$0.hasDirectoryPath && extensions.contains($0.pathExtension.lowercased()) }
            .sorted { before($0.lastPathComponent, $1.lastPathComponent) }
    }

    /// Finder name order.
    static func before(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    static func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
}
