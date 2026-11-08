import AppKit
import PDFKit
import ImageIO
import CryptoKit

@main struct DragWheelTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw DWConversionError("TEST FAILED: " + message) }
    }
    static func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bezel-wheel-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("Photo with ' quotes.png")
        let context = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "create image fixture")
        let original = try data(png)
        let jpg = try await DWConverter.convert(png, to: "jpg")
        let decoded = CGImageSourceCreateWithURL(jpg as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil)!
        try require(image.width == 30 && image.height == 20, "image conversion preserves dimensions")
        try require(CGImageSourceGetType(decoded) as String? == "public.jpeg", "output is a real JPEG")
        let repeated = try await DWConverter.convert(png, to: "jpg")
        try require(repeated.lastPathComponent == "Photo with ' quotes 2.jpg", "existing output is preserved")
        try require(try data(png) == original, "source bytes unchanged")
        let svg = root.appendingPathComponent("Vector.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"20\"><rect width=\"30\" height=\"20\" fill=\"blue\"/></svg>".write(to: svg, atomically: true, encoding: .utf8)
        let svgPNG = try await DWConverter.convert(svg, to: "png")
        try require(CGImageSourceCreateWithURL(svgPNG as CFURL, nil) != nil, "SVG rasterizes to a real PNG")

        let jpeg = root.appendingPathComponent("OTHER.JPEG")
        try FileManager.default.copyItem(at: jpg, to: jpeg)
        try require(DWFormats.classify(jpeg)?.format == "jpg", "case-insensitive aliases")
        try require(!DragWheelService.commonTargets([png, jpeg]).contains("jpg"), "mixed originals intersect target formats")
        let unknown = root.appendingPathComponent("unknown.not-supported")
        try Data().write(to: unknown)
        try require(DragWheelService.commonTargets([png, unknown]).isEmpty, "unsupported batch members never silently disappear")

        let text = root.appendingPathComponent("Read me.txt")
        try "Bezel conversion fixture.\nSecond line.\n".write(to: text, atomically: true, encoding: .utf8)
        let docx = try await DWConverter.convert(text, to: "docx")
        let plain = try await DWConverter.convert(docx, to: "txt")
        try require(try String(contentsOf: plain, encoding: .utf8).contains("Bezel conversion fixture"), "real document conversion round trip")
        let textPDF = try await DWConverter.convert(text, to: "pdf")
        try require(PDFDocument(url: textPDF)?.string?.contains("Bezel conversion fixture") == true, "native document PDF contains actual text")

        let richPDF = try await DWConverter.convert(docx, to: "pdf")
        try require(PDFDocument(url: richPDF)?.string?.contains("Bezel conversion fixture") == true,
                    "bounded document snapshots preserve rich-document PDF conversion")
        let legacyText = root.appendingPathComponent("Legacy.txt")
        try Data([0x43, 0x61, 0x66, 0xE9]).write(to: legacyText)
        let legacyPDF = try await DWConverter.convert(legacyText, to: "pdf")
        try require(PDFDocument(url: legacyPDF)?.string?.contains("Café") == true, "legacy text decoding preserves non-ASCII characters")
        try require(try DWConverter.decodeText(Data("\u{FEFF}hello".utf8)) == "hello", "UTF-8 BOM is removed")

        let vanished = root.appendingPathComponent("Vanished.txt")
        let directory = root.appendingPathComponent("Directory.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oversized = root.appendingPathComponent("Oversized.txt")
        try Data().write(to: oversized)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: UInt64(DWConverter.documentByteLimit + 1))
        try oversizedHandle.close()
        let pipe = root.appendingPathComponent("Pipe.txt")
        try require(mkfifo(pipe.path, 0o600) == 0, "create non-regular source fixture")
        var rejectedInputs = [vanished, directory, oversized, pipe]
        let unreadable = root.appendingPathComponent("Unreadable.txt")
        try Data("private source".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        if getuid() != 0 { rejectedInputs.append(unreadable) }
        for source in rejectedInputs {
            let output = root.appendingPathComponent(source.lastPathComponent + ".pdf")
            do {
                try await DWConverter.documentToPDF(source, src: "txt", out: output, work: root, title: "Rejected")
                throw DWConversionError("TEST FAILED: invalid document produced a PDF: " + source.lastPathComponent)
            } catch {
                try require(!error.localizedDescription.contains("TEST FAILED"), "document source errors propagate")
            }
            try require(!FileManager.default.fileExists(atPath: output.path), "rejected document never creates a blank PDF")
        }

        let csv = root.appendingPathComponent("Table.csv")
        try "Name,Note\r\nAda,\"one\ntwo\"\r\n\"a,b\",\"say \"\"hi\"\"\"\r\n".write(to: csv, atomically: true, encoding: .utf8)
        let tsv = try await DWConverter.convert(csv, to: "tsv")
        let back = try await DWConverter.convert(tsv, to: "csv")
        let rows = DWConverter.parseDelimited(try String(contentsOf: back, encoding: .utf8), separator: ",")
        try require(rows == [["Name", "Note"], ["Ada", "one\ntwo"], ["a,b", "say \"hi\""]], "CSV/TSV quoting and embedded line breaks survive")

        let vtt = root.appendingPathComponent("Caption.vtt")
        try "WEBVTT\n\n00:01.200 --> 00:03.400 align:start\nHello <b>Bezel</b>\n\n".write(to: vtt, atomically: true, encoding: .utf8)
        let srt = try await DWConverter.convert(vtt, to: "srt")
        try require(try String(contentsOf: srt, encoding: .utf8).contains("00:00:01,200 --> 00:00:03,400"), "subtitle timestamps convert")
        let transcript = try await DWConverter.convert(srt, to: "txt")
        try require(try String(contentsOf: transcript, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "Hello Bezel", "subtitle text removes markup")

        let pdf = root.appendingPathComponent("Two pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 120)
        let pdfContext = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        for _ in 0..<2 { pdfContext.beginPDFPage(nil); pdfContext.fill(box); pdfContext.endPDFPage() }
        pdfContext.closePDF()
        let pages = try await DWConverter.convert(pdf, to: "png")
        try require(DWFormats.isDirectory(pages), "multi-page PDF creates a folder")
        let images = try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
        try require(images.count == 2 && images.allSatisfy { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil }, "both PDF pages render as images")
        let imagePDF = try await DWConverter.convert(png, to: "pdf")
        try require(PDFDocument(url: imagePDF)?.pageCount == 1, "image produces a valid one-page PDF")

        let folder = root.appendingPathComponent("-Assets $(literal)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("archive payload".utf8).write(to: folder.appendingPathComponent("payload.txt"))
        let tar = try await DWConverter.convert(folder, to: "tar.gz")
        let zip = try await DWConverter.convert(tar, to: "zip")
        let inspected = try SafeArchive.inspect(zip)
        try require(inspected.entries.contains { $0.path.hasSuffix("payload.txt") }, "folder and archive transcoding preserves content")
        try require(try data(folder.appendingPathComponent("payload.txt")) == Data("archive payload".utf8), "folder source remains intact")

        let bad = URL(fileURLWithPath: CommandLine.arguments[1])
        do { _ = try await DWConverter.convert(bad, to: "zip"); throw DWConversionError("TEST FAILED: unsafe archive accepted") }
        catch { try require(!error.localizedDescription.contains("TEST FAILED"), "archive traversal rejected") }
        do { _ = try await DWConverter.convert(png, to: "mp3"); throw DWConversionError("TEST FAILED: invalid format accepted") }
        catch { try require(!error.localizedDescription.contains("TEST FAILED"), "invalid target rejected") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DWConverter.convert(png, to: "tiff")
        }
        do { _ = try await cancelled.value; throw DWConversionError("TEST FAILED: cancelled conversion completed") }
        catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Photo with ' quotes.tiff").path), "cancellation creates no output")

        var session = DWDragSession()
        session.reset(changeCount: 10)
        try require(!session.update(down: true, changeCount: 10, trigger: true), "stale drag pasteboard ignored")
        try require(session.update(down: true, changeCount: 11, trigger: true), "fresh drag triggers")
        try require(!session.update(down: true, changeCount: 11, trigger: true), "one wheel per drag")
        _ = session.update(down: false, changeCount: 11, trigger: false)
        try require(!session.update(down: true, changeCount: 11, trigger: true), "previous drag cannot trigger a click")
        try require(!session.update(down: true, changeCount: 12, trigger: false), "modifier required")
        try require(session.update(down: true, changeCount: 12, trigger: true), "modifier may be pressed after dragging starts")
        let directoryReply = try await CommandRunner.run(URL(fileURLWithPath: "/bin/pwd"), arguments: [], directory: folder)
        let actualDirectory = URL(fileURLWithPath: directoryReply.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        try require(directoryReply.status == 0 && actualDirectory == folder.resolvingSymlinksInPath(),
                    "converter commands execute in their requested directory")
        let environmentReply = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["BEZEL_CONVERSION_TEST"],
                    environment: ["BEZEL_CONVERSION_TEST": "literal $(no-shell) value"])
        try require(environmentReply.status == 0 && environmentReply.stdout == "literal $(no-shell) value\n", "converter environment passed literally")

        let wheel = DWRadialView(frame: NSRect(x: 0, y: 0, width: 340, height: 340))
        wheel.items = [DWMenuItem(format: "png", enabled: true, note: nil), DWMenuItem(format: "jpg", enabled: false, note: "needs helper")]
        try require(wheel.region(at: NSPoint(x: 170, y: 170)) == .cancel, "center cancels")
        try require(wheel.region(at: NSPoint(x: 10, y: 10)) == .outside, "outside is not a target")
        try require(wheel.region(at: NSPoint(x: 270, y: 170)) == .item(0), "wedge hit testing")

        if let ffmpeg = DWTool.ffmpeg.path {
            let webp = try await DWConverter.convert(png, to: "webp")
            try require(CGImageSourceCreateWithURL(webp as CFURL, nil) != nil, "webp output uses an available encoder")
            let wav = root.appendingPathComponent("Tone.wav")
            try await dwRunCommand(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", wav.path])
            let mp3 = try await DWConverter.convert(wav, to: "mp3")
            try await dwRunCommand(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", mp3.path, "-f", "null", "-"])
            let movie = root.appendingPathComponent("Movie.mp4")
            try await dwRunCommand(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=10", "-t", "0.2", "-c:v", "libx264", "-pix_fmt", "yuv420p", movie.path])
            let webm = try await DWConverter.convert(movie, to: "webm")
            try await dwRunCommand(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", webm.path, "-f", "null", "-"])
            print("FFmpeg audio and video conversion checks passed with real encoded/decoded fixtures.")
        }

        let service = DragWheelService(placeNextToOriginal: false)
        var shelfPairs: [(URL, URL)] = []
        service.onConverted = { source, output in
            shelfPairs.append((source, output))
            return nil
        }
        service.convert([png], to: "tiff")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while service.activeCount > 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(service.jobs.last?.state == .completed, "Bezel service actually executes and reports conversion")
        try require(shelfPairs.count == 1 && shelfPairs[0].0 == png && shelfPairs[0].1 == service.jobs.last?.output,
                    "successful conversion sends original and actual output to Shelf")
        try require(shelfPairs[0].1.deletingLastPathComponent() == png.deletingLastPathComponent(), "Shelf output remains beside original")
        let corrupt = root.appendingPathComponent("Corrupt.png")
        try Data("Not an image".utf8).write(to: corrupt)
        service.convert([corrupt, png], to: "bmp")
        let nextDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while service.activeCount > 0 && ContinuousClock.now < nextDeadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(service.jobs.suffix(2).map(\.state) == [.failed, .completed], "a failed job cannot block the next file")
        try require(shelfPairs.count == 2, "failed conversions never add nonexistent results to Shelf")
        await service.shutdown()
        try require(service.activeCount == 0, "shutdown drains work")
        print("DragWheel checks passed: actual image/document/PDF/subtitle/CSV/folder/archive conversions, bounded document reads and source-error propagation, originals and collisions, mixed formats, unsafe archives, cancellation, drag sessions, wheel hit testing, and Bezel service completion.")
    }
}
