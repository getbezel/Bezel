import Foundation
import Darwin

/// Uses the system libarchive reader and writes regular files into a fresh private staging
/// directory. No archive-provided path, link, device, owner, or extended attribute is trusted.
enum SafeArchive {
    struct EntryInfo: Identifiable, Sendable {
        let id: Int
        let path: String
        let size: Int64
        let isDirectory: Bool
        let warning: String?
    }
    struct Inspection: Sendable {
        let entries: [EntryInfo]
        let isTruncated: Bool
    }
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }

    private final class Reader {
        let library: UnsafeMutableRawPointer
        let archive: OpaquePointer
        let free: @convention(c) (OpaquePointer?) -> Int32
        let next: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
        let read: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
        let name: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        let link: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        let hardlink: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        let type: @convention(c) (OpaquePointer?) -> UInt16
        let permissions: @convention(c) (OpaquePointer?) -> UInt16
        let size: @convention(c) (OpaquePointer?) -> Int64
        let error: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

        init(url: URL) throws {
            guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else {
                throw Failure.message("The system archive library is unavailable.")
            }
            func symbol<T>(_ name: String, as: T.Type) throws -> T {
                guard let address = dlsym(library, name) else { throw Failure.message("The system archive library is missing \(name).") }
                return unsafeBitCast(address, to: T.self)
            }
            do {
                let create = try symbol("archive_read_new", as: (@convention(c) () -> OpaquePointer?).self)
                free = try symbol("archive_read_free", as: (@convention(c) (OpaquePointer?) -> Int32).self)
                next = try symbol("archive_read_next_header", as: (@convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32).self)
                read = try symbol("archive_read_data", as: (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int).self)
                name = try symbol("archive_entry_pathname_utf8", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
                link = try symbol("archive_entry_symlink", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
                hardlink = try symbol("archive_entry_hardlink", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
                type = try symbol("archive_entry_filetype", as: (@convention(c) (OpaquePointer?) -> UInt16).self)
                permissions = try symbol("archive_entry_perm", as: (@convention(c) (OpaquePointer?) -> UInt16).self)
                size = try symbol("archive_entry_size", as: (@convention(c) (OpaquePointer?) -> Int64).self)
                error = try symbol("archive_error_string", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
                let format = try symbol("archive_read_support_format_all", as: (@convention(c) (OpaquePointer?) -> Int32).self)
                let filters = try symbol("archive_read_support_filter_all", as: (@convention(c) (OpaquePointer?) -> Int32).self)
                let open = try symbol("archive_read_open_filename", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32).self)
                guard let pointer = create() else { throw Failure.message("Could not allocate the archive reader.") }
                _ = format(pointer)
                _ = filters(pointer)
                let result = url.path.withCString { open(pointer, $0, 128 * 1024) }
                guard result == 0 else {
                    let description = error(pointer).map(String.init(cString:)) ?? "Unsupported or damaged archive."
                    _ = free(pointer)
                    throw Failure.message(description)
                }
                archive = pointer
                self.library = library
            } catch {
                dlclose(library)
                throw error
            }
        }
        deinit { _ = free(archive); dlclose(library) }
        var errorDescription: String { error(archive).map(String.init(cString:)) ?? "The archive is damaged or uses an unsupported format." }
    }

    /// Reads headers without creating files. Enumeration is bounded because
    /// advancing a compressed TAR may need to decompress the preceding entry.
    static func inspect(_ source: URL) throws -> Inspection {
        try Task.checkCancellation()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let reader = try Reader(url: source)
        var entries: [EntryInfo] = []
        var bytes: Int64 = 0
        let inspectionLimit: Int64 = 512 * 1024 * 1024
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let result = reader.next(reader.archive, &entry)
            if result == 1 { return Inspection(entries: entries, isTruncated: false) }
            guard result == 0, let entry else { throw Failure.message(reader.errorDescription) }
            guard let pointer = reader.name(entry) else { throw Failure.message("An archive entry has no valid UTF-8 filename.") }
            let path = String(cString: pointer)
            let components = path.split(separator: "/")
            let type = reader.type(entry)
            let size = max(0, reader.size(entry))
            let warning: String?
            if path.hasPrefix("/") || path.contains("\\") || path.contains(":") || path.utf8.count >= 4096 || components.contains("..") {
                warning = "Unsafe path"
            } else if reader.link(entry) != nil || reader.hardlink(entry) != nil {
                warning = "Link: extraction is not supported"
            } else if type != UInt16(S_IFREG) && type != UInt16(S_IFDIR) {
                warning = "Special entry: extraction is not supported"
            } else { warning = nil }
            entries.append(EntryInfo(id: entries.count, path: String(path.prefix(4096)), size: size,
                                     isDirectory: type == UInt16(S_IFDIR), warning: warning))
            guard entries.count < 20_000, size <= inspectionLimit - bytes else {
                return Inspection(entries: entries, isTruncated: true)
            }
            bytes += size
        }
    }

    static func extract(_ source: URL, into destination: URL) throws -> URL {
        try Task.checkCancellation()
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if destinationAccess { destination.stopAccessingSecurityScopedResource() }
        }
        let manager = FileManager.default
        let parent = destination.resolvingSymlinksInPath().standardizedFileURL
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.message("Choose a destination folder.") }
        let base = source.deletingPathExtension().lastPathComponent
        var output = parent.appendingPathComponent(base.isEmpty ? "Extracted Archive" : base, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: output.path) {
            output = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        let staging = parent.appendingPathComponent(".bezel-extract-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? manager.removeItem(at: staging) } }
        let reader = try Reader(url: source)
        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        let byteLimit: Int64 = 32 * 1024 * 1024 * 1024
        var actualBytes: Int64 = 0
        var declaredBytes: Int64 = 0
        var entries = 0
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let result = reader.next(reader.archive, &entry)
            if result == 1 { break } // ARCHIVE_EOF
            guard result == 0, let entry else { throw Failure.message(reader.errorDescription) }
            entries += 1
            guard entries <= 200_000 else { throw Failure.message("This archive exceeds the 200,000-entry extraction limit.") }
            guard let namePointer = reader.name(entry) else { throw Failure.message("An archive entry has no valid UTF-8 filename.") }
            let name = String(cString: namePointer)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), name.utf8.count < 4096 else {
                throw Failure.message("The archive contains an unsafe filename.")
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
            guard !components.contains("..") else { throw Failure.message("The archive contains a path outside its destination folder.") }
            guard reader.link(entry) == nil, reader.hardlink(entry) == nil else {
                throw Failure.message("This archive contains links. For safe extraction, Bezel accepts regular files and folders only.")
            }
            let type = reader.type(entry)
            guard type == UInt16(S_IFDIR) || type == UInt16(S_IFREG) else {
                throw Failure.message("This archive contains a special device or unsupported entry.")
            }
            if components.isEmpty {
                guard type == UInt16(S_IFDIR) else { throw Failure.message("An archive entry has an empty filename.") }
                continue
            }
            let target = components.reduce(staging) { $0.appendingPathComponent($1) }.standardizedFileURL
            guard target.path.hasPrefix(staging.path + "/") else { throw Failure.message("The archive contains an unsafe destination.") }
            if type == UInt16(S_IFDIR) {
                try manager.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                continue
            }
            let expected = reader.size(entry)
            guard expected >= 0, expected <= byteLimit - declaredBytes else { throw Failure.message("This archive exceeds the 32 GB extraction limit.") }
            declaredBytes += expected
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = target.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600 | (reader.permissions(entry) & 0o111))) }
            guard descriptor >= 0 else { throw Failure.message("A filename is duplicated or cannot be created: \(target.lastPathComponent)") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                while true {
                    try Task.checkCancellation()
                    let count = reader.read(reader.archive, buffer, bufferSize)
                    guard count >= 0 else { throw Failure.message(reader.errorDescription) }
                    if count == 0 { break }
                    guard Int64(count) <= byteLimit - actualBytes else { throw Failure.message("This archive exceeds the 32 GB extraction limit.") }
                    actualBytes += Int64(count)
                    try handle.write(contentsOf: Data(bytes: buffer, count: count))
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: output)
        committed = true
        return output
    }

    static func compress(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourcePath != destinationPath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw Failure.message("Save the archive outside the folder being compressed.")
        }
        guard !manager.fileExists(atPath: destination.path) else { throw Failure.message("Choose a new filename. Bezel does not overwrite existing archives.") }
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer { if sourceAccess { source.stopAccessingSecurityScopedResource() }; if destinationAccess { destination.stopAccessingSecurityScopedResource() } }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".bezel-archive-\(UUID().uuidString).zip")
        let diagnostics = manager.temporaryDirectory.appendingPathComponent("bezel-archive-\(UUID().uuidString).log")
        manager.createFile(atPath: diagnostics.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? manager.removeItem(at: temp); try? manager.removeItem(at: diagnostics) }
        let log = try FileHandle(forWritingTo: diagnostics)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, temp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log
        try process.run()
        // Polling stays on the utility worker and allows cooperative cancellation of ditto.
        while process.isRunning {
            if Task.isCancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let description = (try? String(contentsOf: diagnostics, encoding: .utf8))?.prefix(1500)
            throw Failure.message(description.map(String.init) ?? "The archive could not be created.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: temp, to: destination)
    }
}
