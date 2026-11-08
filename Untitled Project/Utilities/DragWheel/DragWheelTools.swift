// Adapted from the user-provided DragWheel source archive (revision 9fc8867).
import Foundation

/// Optional helper tools (installed via Homebrew) that unlock some conversions.
enum DWTool: String, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }
    case ffmpeg, pandoc, soffice, magick

    var displayName: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .pandoc: return "Pandoc"
        case .soffice: return "LibreOffice"
        case .magick: return "ImageMagick"
        }
    }

    var usedFor: String {
        switch self {
        case .ffmpeg: return "audio, video"
        case .pandoc: return "epub, markdown"
        case .soffice: return "presentations, spreadsheets"
        case .magick: return "webp/avif output (if macOS can't)"
        }
    }

    var brewInstall: String {
        switch self {
        case .soffice: return "brew install --cask libreoffice"
        case .magick: return "brew install imagemagick"
        default: return "brew install \(rawValue)"
        }
    }

    var path: String? { DWToolLocator.find(self) }
}

enum DWToolLocator {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin"]

    static func find(_ tool: DWTool) -> String? {
        if tool == .soffice {
            let candidates = [
                "/Applications/LibreOffice.app/Contents/MacOS/soffice",
                NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            ]
            if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        }
        return find(named: tool.rawValue)
    }

    static func find(named name: String) -> String? {
        searchDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct DWConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reuses Bezel's bounded, cancelable subprocess runner; no shell commands.
@discardableResult
func dwRunCommand(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                  extraEnv: [String: String] = [:]) async throws -> String {
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = DWToolLocator.searchDirs.joined(separator: ":")
    environment.merge(extraEnv) { _, new in new }
    let result = try await CommandRunner.run(URL(fileURLWithPath: executable), arguments: arguments,
        timeout: 1800, outputLimit: 512 * 1024, directory: cwd, environment: environment)
    guard result.status == 0 else {
        let detail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " ")
        throw DWConversionError("\(URL(fileURLWithPath: executable).lastPathComponent): \(detail.isEmpty ? "conversion failed" : String(detail.prefix(600)))")
    }
    return result.stdout
}
