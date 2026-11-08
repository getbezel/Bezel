// Adapted from the user-provided DragWheel source archive (revision 9fc8867).
import Foundation

enum DWFileKind: String, Sendable {
    case image, audio, video, pdf, document, presentation, spreadsheet, subtitle, archive, folder
}

/// The conversion table (matches the spec screenshot).
enum DWFormats {
    static let aliases: [String: String] = [
        "jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic",
        "htm": "html", "markdown": "md", "aif": "aiff", "tgz": "tar.gz",
    ]

    static let table: [(kind: DWFileKind, from: [String], to: [String])] = [
        (.image, ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "gif", "svg"],
                 ["jpg", "png", "webp", "tiff", "avif", "bmp", "pdf"]),
        (.audio, ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
                 ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]),
        (.video, ["mp4", "mov", "mkv", "webm", "avi", "wmv"],
                 ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]),
        (.pdf, ["pdf"],
               ["docx", "jpg", "png", "epub", "txt", "md"]),
        (.document, ["docx", "doc", "odt", "rtf", "md", "txt", "epub", "html"],
                    ["docx", "md", "txt", "epub", "html", "pdf", "jpg", "png"]),
        (.presentation, ["pptx", "ppt", "odp"],
                        ["pdf", "jpg", "png"]),
        (.spreadsheet, ["xlsx", "xls", "ods", "csv", "tsv"],
                       ["xlsx", "ods", "csv", "tsv", "pdf"]),
        (.subtitle, ["srt", "vtt"],
                    ["srt", "vtt", "txt"]),
        (.archive, ["zip", "tar", "tar.gz", "rar"],
                   ["zip", "tar", "tar.gz"]),
        (.folder, ["folder"],
                  ["zip", "tar", "tar.gz"]),
    ]

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func format(of url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "tar.gz" }
        let ext = url.pathExtension.lowercased()
        return aliases[ext] ?? ext
    }

    static func classify(_ url: URL) -> (kind: DWFileKind, format: String)? {
        if isDirectory(url) { return (.folder, "folder") }
        let f = format(of: url)
        for row in table where row.kind != .folder && row.from.contains(f) {
            return (row.kind, f)
        }
        return nil
    }

    /// Target formats for a file, excluding its own format.
    static func targets(for url: URL) -> [String] {
        guard let c = classify(url), let row = table.first(where: { $0.kind == c.kind }) else { return [] }
        return row.to.filter { $0 != c.format }
    }

    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        if isDirectory(url) { return name }
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        if lower.hasSuffix(".tgz") { return String(name.dropLast(4)) }
        return url.deletingPathExtension().lastPathComponent
    }
}
