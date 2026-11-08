// Adapted from the user-provided DragWheel source archive (revision 9fc8867).
import AppKit
import PDFKit
import ImageIO
import Darwin

/// Does the actual conversions. Always called off the main thread.
/// Every conversion writes into a private temp folder, then moves the result
/// next to the original (never touching the original).
enum DWConverter {
    static let textutil = "/usr/bin/textutil"
    static let ditto = "/usr/bin/ditto"
    static let tar = "/usr/bin/tar"

    // MARK: - Requirements

    /// Name of the helper tool this conversion still needs, or nil if it can run.
    static func missingRequirement(for url: URL, to dst: String) -> String? {
        guard let c = DWFormats.classify(url) else { return "support" }
        let src = c.format
        switch c.kind {
        case .image:
            if (dst == "webp" || dst == "avif") && !DWImageWriter.canEncode(dst)
                && DWTool.magick.path == nil && DWTool.ffmpeg.path == nil { return "ImageMagick" }
            return nil
        case .audio:
            if DWTool.ffmpeg.path != nil { return nil }
            let nativeIn: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac"]
            let nativeOut: Set<String> = ["wav", "aiff", "m4a"]
            return nativeIn.contains(src) && nativeOut.contains(dst) ? nil : "FFmpeg"
        case .video:
            return DWTool.ffmpeg.path == nil ? "FFmpeg" : nil
        case .pdf:
            return dst == "epub" && DWTool.pandoc.path == nil ? "Pandoc" : nil
        case .document:
            return (src == "epub" || dst == "epub") && DWTool.pandoc.path == nil ? "Pandoc" : nil
        case .presentation:
            return DWTool.soffice.path == nil ? "LibreOffice" : nil
        case .spreadsheet:
            let delimited: Set<String> = ["csv", "tsv"]
            if delimited.contains(src) && delimited.contains(dst) { return nil }
            return DWTool.soffice.path == nil ? "LibreOffice" : nil
        case .subtitle, .archive, .folder:
            return nil
        }
    }

    // MARK: - Entry point

    /// Converts `input` to `dst` and returns the URL of the new file beside the original.
    static func convert(_ input: URL, to dst: String) async throws -> URL {
        try Task.checkCancellation()
        guard input.isFileURL, DWFormats.targets(for: input).contains(dst) else {
            throw DWConversionError("Choose a supported output format different from the original.")
        }
        let access = input.startAccessingSecurityScopedResource()
        defer { if access { input.stopAccessingSecurityScopedResource() } }
        guard let c = DWFormats.classify(input) else { throw DWConversionError("Unsupported file type.") }
        if let missing = missingRequirement(for: input, to: dst) {
            throw DWConversionError("\(missing) is needed for .\(c.format) → .\(dst). See Bezel → DragWheel → Helper Tools.")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Bezel-Convert-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        let base = DWFormats.baseName(of: input)
        let out = work.appendingPathComponent("\(base).\(dst)")
        let src = c.format

        let produced: URL
        switch c.kind {
        case .image:        produced = try await convertImage(input, dst: dst, out: out, work: work)
        case .audio:        produced = try await convertAudio(input, src: src, dst: dst, out: out)
        case .video:        produced = try await convertVideo(input, dst: dst, out: out)
        case .pdf:          produced = try await convertPDF(input, dst: dst, out: out, work: work, base: base)
        case .document:     produced = try await convertDocument(input, src: src, dst: dst, out: out, work: work, base: base)
        case .presentation: produced = try await convertPresentation(input, dst: dst, work: work, base: base)
        case .spreadsheet:  produced = try await convertSpreadsheet(input, src: src, dst: dst, out: out, work: work, base: base)
        case .subtitle:     produced = try convertSubtitle(input, dst: dst, out: out)
        case .archive:      produced = try await convertArchive(input, src: src, dst: dst, out: out, work: work)
        case .folder:       produced = try await archiveFolder(input, dst: dst, out: out)
        }

        guard fm.fileExists(atPath: produced.path) else { throw DWConversionError("The converter produced no output.") }
        try Task.checkCancellation()
        let final = uniqueURL(in: input.deletingLastPathComponent(),
                              name: produced.lastPathComponent,
                              isDirectory: DWFormats.isDirectory(produced))
        try fm.moveItem(at: produced, to: final)
        return final
    }

    /// "photo.png" → "photo 2.png" if taken.
    static func uniqueURL(in dir: URL, name: String, isDirectory: Bool) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext: String
        if isDirectory { ext = "" }
        else if name.lowercased().hasSuffix(".tar.gz") { ext = "tar.gz" }
        else { ext = (name as NSString).pathExtension }
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        repeat {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: - Images

    static func convertImage(_ input: URL, dst: String, out: URL, work: URL) async throws -> URL {
        let image: CGImage
        if let img = DWImageWriter.load(input) { image = img }
        else { image = try await rasterizeExternally(input, work: work) }

        if dst == "pdf" {
            try DWImageWriter.writePDF(image, to: out)
            return out
        }
        if DWImageWriter.canEncode(dst) {
            try DWImageWriter.write(image, to: out, format: dst)
            return out
        }
        // webp / avif when macOS can't encode them: go through a PNG and a helper tool.
        let png = work.appendingPathComponent("intermediate.png")
        try DWImageWriter.write(image, to: png, format: "png")
        if let magick = DWTool.magick.path {
            try await dwRunCommand(magick, [png.path, "-quality", "88", out.path])
        } else if let ffmpeg = DWTool.ffmpeg.path {
            var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", png.path]
            if dst == "avif" { args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "30", "-pix_fmt", "yuv420p"] }
            if dst == "webp" { args += ["-c:v", "libwebp", "-quality", "88"] }
            try await dwRunCommand(ffmpeg, args + [out.path])
        } else {
            throw DWConversionError("Install ImageMagick to export .\(dst).")
        }
        return out
    }

    static func rasterizeExternally(_ input: URL, work: URL) async throws -> CGImage {
        let png = work.appendingPathComponent("raster.png")
        if let rsvg = DWToolLocator.find(named: "rsvg-convert") {
            try await dwRunCommand(rsvg, ["-z", "2", "-o", png.path, input.path])
        } else if let magick = DWTool.magick.path {
            try await dwRunCommand(magick, ["-density", "192", input.path, png.path])
        } else {
            throw DWConversionError("macOS couldn't read this image. Installing ImageMagick may help.")
        }
        guard let img = DWImageWriter.load(png) else { throw DWConversionError("Couldn't read this image.") }
        return img
    }

    // MARK: - Audio / Video (FFmpeg)

    static let ffmpegBase = ["-y", "-hide_banner", "-loglevel", "error", "-nostdin"]

    static func convertAudio(_ input: URL, src: String, dst: String, out: URL) async throws -> URL {
        if let ffmpeg = DWTool.ffmpeg.path {
            let codec: [String]
            switch dst {
            case "mp3":  codec = ["-c:a", "libmp3lame", "-q:a", "2"]
            case "m4a":  codec = ["-c:a", "aac", "-b:a", "256k"]
            case "wav":  codec = ["-c:a", "pcm_s16le"]
            case "flac": codec = ["-c:a", "flac"]
            case "ogg":  codec = ["-c:a", "libvorbis", "-q:a", "6"]
            case "opus": codec = ["-c:a", "libopus", "-b:a", "160k"]
            case "aiff": codec = ["-c:a", "pcm_s16be"]
            case "wma":  codec = ["-c:a", "wmav2", "-b:a", "192k"]
            default:     codec = []
            }
            try await dwRunCommand(ffmpeg, ffmpegBase + ["-i", input.path, "-vn", "-map_metadata", "0"] + codec + [out.path])
            return out
        }
        // Built-in fallback (no FFmpeg): afconvert handles wav / aiff / m4a.
        let args: [String]
        switch dst {
        case "wav":  args = ["-f", "WAVE", "-d", "LEI16"]
        case "aiff": args = ["-f", "AIFF", "-d", "BEI16"]
        case "m4a":  args = ["-f", "m4af", "-d", "aac", "-b", "256000"]
        default: throw DWConversionError("FFmpeg is needed for .\(dst).")
        }
        try await dwRunCommand("/usr/bin/afconvert", args + [input.path, out.path])
        return out
    }

    static func convertVideo(_ input: URL, dst: String, out: URL) async throws -> URL {
        guard let ffmpeg = DWTool.ffmpeg.path else { throw DWConversionError("FFmpeg is needed for video.") }
        let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        let opts: [String]
        switch dst {
        case "mp4", "mov":
            opts = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-vf", even,
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mkv":
            opts = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-vf", even,
                    "-c:a", "aac", "-b:a", "192k"]
        case "webm":
            opts = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            opts = ["-c:v", "mpeg4", "-q:v", "3", "-vf", even, "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv":
            opts = ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif":
            opts = ["-an", "-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0"]
        case "mp3":
            opts = ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        default:
            opts = []
        }
        try await dwRunCommand(ffmpeg, ffmpegBase + ["-i", input.path] + opts + [out.path])
        return out
    }

    // MARK: - PDF

    static func convertPDF(_ input: URL, dst: String, out: URL, work: URL, base: String) async throws -> URL {
        if dst == "jpg" || dst == "png" {
            return try renderPDFPages(input, format: dst, base: base, work: work)
        }
        guard let doc = PDFDocument(url: input) else { throw DWConversionError("Couldn't open the PDF.") }
        guard doc.pageCount <= 1000 else { throw DWConversionError("PDF conversion supports up to 1,000 pages at a time.") }
        var pages: [String] = []
        var textBytes = 0
        for index in 0..<doc.pageCount {
            try Task.checkCancellation()
            if let text = doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
                textBytes += text.utf8.count
                guard textBytes <= 32 * 1024 * 1024 else { throw DWConversionError("The PDF contains more than 32 MB of text.") }
                pages.append(text)
            }
        }
        switch dst {
        case "txt":
            try pages.joined(separator: "\n\n").write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try pages.joined(separator: "\n\n---\n\n").write(to: out, atomically: true, encoding: .utf8)
        case "docx":
            let txt = work.appendingPathComponent("\(base).txt")
            try pages.joined(separator: "\n\n").write(to: txt, atomically: true, encoding: .utf8)
            try await dwRunCommand(textutil, ["-convert", "docx", "-output", out.path, txt.path])
        case "epub":
            let md = work.appendingPathComponent("\(base).md")
            try pages.joined(separator: "\n\n").write(to: md, atomically: true, encoding: .utf8)
            try await pandoc(md, src: "md", dst: "epub", out: out, work: work, title: base)
        default:
            throw DWConversionError("Unsupported target.")
        }
        return out
    }

    /// One page → a single image. Several pages → a folder "name (png)" with one image per page.
    static func renderPDFPages(_ pdf: URL, format: String, base: String, work: URL) throws -> URL {
        guard let doc = PDFDocument(url: pdf), doc.pageCount > 0 else { throw DWConversionError("Couldn't open the PDF.") }
        guard doc.pageCount <= 1000 else { throw DWConversionError("Export up to 1,000 PDF pages at a time.") }
        let dir = work.appendingPathComponent("render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func render(_ i: Int, to url: URL) throws {
            guard let page = doc.page(at: i) else { return }
            var size = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= 6000, size.height <= 6000, size.width * size.height <= 20_000_000 else {
                throw DWConversionError("This PDF page is too large to render safely.")
            }
            let thumb = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
            guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw DWConversionError("Couldn't render page \(i + 1).")
            }
            try DWImageWriter.write(cg, to: url, format: format)
        }

        if doc.pageCount == 1 {
            let out = dir.appendingPathComponent("\(base).\(format)")
            try render(0, to: out)
            return out
        }
        let folder = dir.appendingPathComponent("\(base) (\(format))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            let num = String(format: "%0\(digits)d", i + 1)
            try render(i, to: folder.appendingPathComponent("\(base)-\(num).\(format)"))
        }
        return folder
    }

    // MARK: - Documents

    static let textutilReadable: Set<String> = ["doc", "docx", "odt", "rtf", "txt", "html"]

    static func convertDocument(_ input: URL, src: String, dst: String, out: URL, work: URL, base: String) async throws -> URL {
        switch dst {
        case "pdf":
            try await documentToPDF(input, src: src, out: out, work: work, title: base)
            return out
        case "jpg", "png":
            let pdf = work.appendingPathComponent("render-source.pdf")
            try await documentToPDF(input, src: src, out: pdf, work: work, title: base)
            return try renderPDFPages(pdf, format: dst, base: base, work: work)
        case "md":
            if src == "txt" {
                try FileManager.default.copyItem(at: input, to: out)
            } else if DWTool.pandoc.path != nil {
                try await pandoc(input, src: src, dst: "md", out: out, work: work, title: base)
            } else {
                try await dwRunCommand(textutil, ["-convert", "txt", "-output", out.path, input.path])
            }
            return out
        case "epub":
            try await pandoc(input, src: src, dst: "epub", out: out, work: work, title: base)
            return out
        default: // txt, html, docx
            if textutilReadable.contains(src) {
                try await dwRunCommand(textutil, ["-convert", dst, "-output", out.path, input.path])
            } else if DWTool.pandoc.path != nil {
                try await pandoc(input, src: src, dst: dst, out: out, work: work, title: base)
            } else if src == "md" {
                // No Pandoc: treat Markdown as plain text.
                let txt = work.appendingPathComponent("md-as-text.txt")
                try FileManager.default.copyItem(at: input, to: txt)
                try await dwRunCommand(textutil, ["-convert", dst, "-output", out.path, txt.path])
            } else {
                throw DWConversionError("Pandoc is needed for .\(src) files.")
            }
            return out
        }
    }

    static func pandocReader(_ src: String) -> String {
        switch src {
        case "md", "txt": return "markdown"
        default: return src   // html, docx, odt, epub, rtf
        }
    }

    static func pandoc(_ input: URL, src: String, dst: String, out: URL, work: URL, title: String) async throws {
        guard let pandoc = DWTool.pandoc.path else { throw DWConversionError("Pandoc is needed (brew install pandoc).") }
        var source = input
        var from = pandocReader(src)
        if src == "doc" || src == "rtf" {   // pandoc can't read .doc; route both through docx for reliability
            let tmp = work.appendingPathComponent("pandoc-in.docx")
            try await dwRunCommand(textutil, ["-convert", "docx", "-output", tmp.path, input.path])
            source = tmp; from = "docx"
        }
        var args = ["-f", from, "-o", out.path]
        switch dst {
        case "md":   args += ["-t", "gfm", "--wrap=none"]
        case "txt":  args += ["-t", "plain", "--wrap=none"]
        case "html": args += ["-t", "html", "-s", "--metadata", "pagetitle=\(title)"]
        case "epub": args += ["-t", "epub", "--metadata", "title=\(title)"]
        case "docx": args += ["-t", "docx"]
        default: break
        }
        args.append(source.path)
        // cwd = original folder so relative image paths resolve
        try await dwRunCommand(pandoc, args, cwd: input.deletingLastPathComponent())
    }

    /// Renders a text document to a paginated US-Letter PDF using Cocoa's text system.
    static func documentToPDF(_ input: URL, src: String, out: URL, work: URL, title: String) async throws {
        var source = input
        var format = src
        if src == "md" || src == "epub" {
            if DWTool.pandoc.path != nil {
                let html = work.appendingPathComponent("pdf-source.html")
                try await pandoc(input, src: src, dst: "html", out: html, work: work, title: title)
                source = html; format = "html"
            } else {
                format = "txt"
            }
        }
        // Read one bounded snapshot on the conversion executor, before entering
        // AppKit. A missing/unreadable source must never become a blank PDF.
        let sourceData = try readDocumentData(source)
        let sourceFormat = format
        let richFormats: Set<String> = ["docx", "doc", "odt", "rtf", "html"]
        let plainText = richFormats.contains(format) ? nil : try decodeText(sourceData)
        try Task.checkCancellation()
        try await MainActor.run {
            try Task.checkCancellation()
            let text = try attributedString(from: sourceData, plainText: plainText, format: sourceFormat,
                                            baseURL: input.deletingLastPathComponent())
            try printPDF(text, to: out)
        }
    }

    @MainActor static func attributedString(from data: Data, plainText: String?, format: String, baseURL: URL) throws -> NSAttributedString {
        let type: NSAttributedString.DocumentType
        switch format {
        case "docx": type = .officeOpenXML
        case "doc":  type = .docFormat
        case "odt":  type = .openDocument
        case "rtf":  type = .rtf
        case "html": type = .html
        default:     type = .plain
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .html {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
            options[.baseURL] = baseURL
        }
        if type == .plain {
            guard let plainText else { throw DWConversionError("Couldn't decode this text document.") }
            return NSAttributedString(string: plainText, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black,
            ])
        }
        return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    @MainActor static func printPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width: CGFloat = 612 - 108
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.drawsBackground = true
        tv.isVerticallyResizable = true
        tv.textContainerInset = .zero
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(text)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            tv.frame.size.height = max(lm.usedRect(for: tc).height, 10)
        }

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw DWConversionError("Couldn't create the PDF.")
        }
    }

    // MARK: - Presentations (LibreOffice)

    static func convertPresentation(_ input: URL, dst: String, work: URL, base: String) async throws -> URL {
        let pdf = try await soffice(input, convertTo: "pdf", outExt: "pdf", work: work)
        if dst == "pdf" { return pdf }
        return try renderPDFPages(pdf, format: dst, base: base, work: work)
    }

    static func soffice(_ input: URL, convertTo filter: String, outExt: String, work: URL, extraArgs: [String] = []) async throws -> URL {
        guard let soffice = DWTool.soffice.path else { throw DWConversionError("LibreOffice is needed (brew install --cask libreoffice).") }
        let outDir = work.appendingPathComponent("lo-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Private profile so it works even while LibreOffice is open.
        let profile = work.appendingPathComponent("LibreOfficeProfile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        try await dwRunCommand(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                                 "--convert-to", filter, "--outdir", outDir.path] + extraArgs + [input.path])
        let produced = outDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + outExt)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw DWConversionError("LibreOffice didn't produce a .\(outExt) file.")
        }
        return produced
    }

    // MARK: - Spreadsheets

    static func convertSpreadsheet(_ input: URL, src: String, dst: String, out: URL, work: URL, base: String) async throws -> URL {
        let delimited: Set<String> = ["csv", "tsv"]
        if delimited.contains(src) && delimited.contains(dst) {
            let rows = parseDelimited(try readText(input), separator: src == "tsv" ? "\t" : ",")
            try writeDelimited(rows, tsv: dst == "tsv").write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        var source = input
        if src == "tsv" {   // LibreOffice imports CSV most reliably
            source = work.appendingPathComponent("\(base).csv")
            let rows = parseDelimited(try readText(input), separator: "\t")
            try writeDelimited(rows, tsv: false).write(to: source, atomically: true, encoding: .utf8)
        }
        let infilter = source.pathExtension.lowercased() == "csv" ? ["--infilter=CSV:44,34,76"] : []
        let filter: String
        switch dst {
        case "csv":  filter = "csv:Text - txt - csv (StarCalc):44,34,76"
        case "tsv":  filter = "tsv:Text - txt - csv (StarCalc):9,34,76"
        case "xlsx": filter = "xlsx:Calc MS Excel 2007 XML"
        case "ods":  filter = "ods"
        default:     filter = "pdf"
        }
        return try await soffice(source, convertTo: filter, outExt: dst, work: work, extraArgs: infilter)
    }

    static let documentByteLimit = 32 * 1024 * 1024

    /// A size check alone races a changing file. Read at most the limit plus
    /// one byte, and reject non-regular files before a pipe/device can block.
    static func readDocumentData(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL else { throw DWConversionError("Choose a local document file.") }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DWConversionError("Choose a regular document file.") }
        guard info.st_size >= 0, info.st_size <= documentByteLimit else {
            throw DWConversionError("Text and document conversions are limited to 32 MB per file.")
        }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1024, documentByteLimit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= documentByteLimit else {
                throw DWConversionError("Text and document conversions are limited to 32 MB per file.")
            }
        }
    }

    static func decodeText(_ data: Data) throws -> String {
        guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw DWConversionError("Couldn't decode this text document.")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    static func readText(_ url: URL) throws -> String {
        try decodeText(readDocumentData(url))
    }

    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func writeDelimited(_ rows: [[String]], tsv: Bool) -> String {
        let lines = rows.map { row -> String in
            row.map { field -> String in
                let separator: Character = tsv ? "\t" : ","
                let needsQuotes = field.contains(where: { $0 == separator || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: tsv ? "\t" : ",")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Subtitles

    struct Cue { var start: String; var end: String; var lines: [String] }

    static func convertSubtitle(_ input: URL, dst: String, out: URL) throws -> URL {
        let cues = parseSubtitles(try readText(input))
        guard !cues.isEmpty else { throw DWConversionError("No subtitle cues found.") }
        let text: String
        switch dst {
        case "srt":
            text = cues.enumerated().map { i, cue in
                "\(i + 1)\n\(cue.start.replacingOccurrences(of: ".", with: ",")) --> \(cue.end.replacingOccurrences(of: ".", with: ","))\n\(cue.lines.joined(separator: "\n"))\n"
            }.joined(separator: "\n")
        case "vtt":
            text = "WEBVTT\n\n" + cues.map { "\($0.start) --> \($0.end)\n\($0.lines.joined(separator: "\n"))\n" }.joined(separator: "\n")
        default: // txt
            var lines: [String] = []
            for cue in cues {
                for line in cue.lines {
                    let clean = line
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if !clean.isEmpty && clean != lines.last { lines.append(clean) }
                }
            }
            text = lines.joined(separator: "\n") + "\n"
        }
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func parseSubtitles(_ raw: String) -> [Cue] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        var block: [String] = []

        func normalizeTime(_ t: String) -> String {
            var s = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if s.split(separator: ":").count == 2 { s = "00:" + s }
            if !s.contains(".") { s += ".000" }
            return s
        }
        func flush() {
            defer { block = [] }
            guard let idx = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let parts = block[idx].components(separatedBy: "-->")
            guard parts.count == 2 else { return }
            let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let text = Array(block[(idx + 1)...])
            cues.append(Cue(start: normalizeTime(parts[0]), end: normalizeTime(endToken), lines: text))
        }
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(line) }
        }
        flush()
        return cues
    }

    // MARK: - Archives & folders

    static let tarEnv = ["COPYFILE_DISABLE": "1"]   // no ._ AppleDouble junk

    static func convertArchive(_ input: URL, src: String, dst: String, out: URL, work: URL) async throws -> URL {
        let extract = try SafeArchive.extract(input, into: work)
        let entries = try FileManager.default.contentsOfDirectory(atPath: extract.path)
        guard !entries.isEmpty else { throw DWConversionError("The archive is empty.") }

        switch dst {
        case "zip":
            try await dwRunCommand(ditto, ["-c", "-k", "--sequesterRsrc", extract.path, out.path])
        case "tar":
            try await dwRunCommand(tar, ["-cf", out.path, "-C", extract.path, "--"] + entries, extraEnv: tarEnv)
        default:
            try await dwRunCommand(tar, ["-czf", out.path, "-C", extract.path, "--"] + entries, extraEnv: tarEnv)
        }
        return out
    }

    static func archiveFolder(_ folder: URL, dst: String, out: URL) async throws -> URL {
        let parent = folder.deletingLastPathComponent().path
        let name = folder.lastPathComponent
        switch dst {
        case "zip":
            try await dwRunCommand(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, out.path])
        case "tar":
            try await dwRunCommand(tar, ["-cf", out.path, "-C", parent, "--", name], extraEnv: tarEnv)
        default:
            try await dwRunCommand(tar, ["-czf", out.path, "-C", parent, "--", name], extraEnv: tarEnv)
        }
        return out
    }
}

// MARK: - ImageIO helpers

enum DWImageWriter {
    static let utis: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "tiff": "public.tiff", "bmp": "com.microsoft.bmp",
        "gif": "com.compuserve.gif", "webp": "org.webmproject.webp", "avif": "public.avif", "heic": "public.heic",
    ]

    static let encodable: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    static func canEncode(_ format: String) -> Bool {
        guard let uti = utis[format] else { return false }
        return encodable.contains(uti)
    }

    /// Loads the first frame, applying EXIF orientation. Falls back to NSImage (covers SVG on newer macOS).
    static func load(_ url: URL) -> CGImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard w > 0, h > 0, w <= 12000, h <= 12000, w * h <= 80_000_000 else { return nil }
            if max(w, h) > 0 {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
            }
            if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        }
        guard let ns = NSImage(contentsOf: url), ns.size.width > 0, ns.size.height > 0 else { return nil }
        guard ns.size.width.isFinite, ns.size.height.isFinite,
              ns.size.width <= 6000, ns.size.height <= 6000 else { return nil }
        let w = Int(ns.size.width * 2), h = Int(ns.size.height * 2)
        guard w > 0, h > 0, w <= 12000, h <= 12000, w * h <= 80_000_000 else { return nil }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func write(_ image: CGImage, to url: URL, format: String) throws {
        guard let uti = utis[format] else { throw DWConversionError("Can't write .\(format).") }
        let img = (format == "jpg" || format == "bmp") ? (flatten(image) ?? image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw DWConversionError("macOS can't write .\(format).")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DWConversionError("Couldn't write the .\(format) file.") }
    }

    /// JPEG/BMP have no alpha: put transparent pixels on white instead of black.
    static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    static func writePDF(_ image: CGImage, to url: URL) throws {
        var size = NSSize(width: image.width, height: image.height)
        let maxSide: CGFloat = 1584   // cap pages at 22 inches
        if max(size.width, size.height) > maxSide {
            let s = maxSide / max(size.width, size.height)
            size = NSSize(width: size.width * s, height: size.height * s)
        }
        let doc = PDFDocument()
        guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else {
            throw DWConversionError("Couldn't create the PDF page.")
        }
        doc.insert(page, at: 0)
        guard doc.write(to: url) else { throw DWConversionError("Couldn't write the PDF.") }
    }
}
