import Foundation
import ImageIO

/// Metadata stored directly in the PNG chunk / JPEG segment structure that ImageIO doesn't expose:
/// C2PA content credentials (`caBX` chunks, APP11 JUMBF segments), PNG text chunks such as
/// "Raw profile type APP1" (EXIF as hex text, often with a thumbnail), `tIME`, private chunks,
/// JPEG comments, and vendor APP segments. Scanning reads headers only; stripping streams the file
/// through a temp copy in 1 MB pieces, so pixel data is copied byte for byte and never decoded.
enum ContainerMetadata {
    struct Block: Sendable {
        /// Chunk type ("caBX"), "type:keyword" for PNG text chunks, or a JPEG marker name ("APP11").
        let id: String
        let label: String
        var size: Int
        var count: Int
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Ancillary chunks that affect how the picture looks or animates; never removed.
    /// `eXIf` and the XMP `iTXt` are listed by ImageIO in the EXIF/XMP sections instead.
    private static let pngKeep: Set<String> = [
        "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "bKGD", "pHYs", "hIST", "sPLT",
        "acTL", "fcTL", "fdAT", "cICP", "mDCV", "cLLI", "eXIf",
    ]
    private static let xmpKeyword = "XML:com.adobe.xmp"
    private static let pieceSize = 1 << 20

    enum Format { case png, jpeg }

    static func format(_ path: String) -> Format? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
        if head == pngSignature { return .png }
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        return nil
    }

    // MARK: - Scan

    static func scan(_ path: String) -> [Block] {
        guard let format = format(path), let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var blocks: [Block] = []
        func add(_ id: String, _ label: String, _ size: Int) {
            if let index = blocks.firstIndex(where: { $0.id == id }) {
                blocks[index].size += size
                blocks[index].count += 1
            } else {
                blocks.append(Block(id: id, label: label, size: size, count: 1))
            }
        }
        switch format {
        case .png:
            walkPNG(handle) { type, length, peek in
                guard let id = pngRemovableID(type, peek) else { return }
                add(id, pngLabel(type, id: id, peek: peek), length)
            }
        case .jpeg:
            walkJPEG(handle) { marker, length, peek in
                guard let id = jpegRemovableID(marker) else { return }
                add(id, jpegLabel(marker, peek: peek), length)
            }
        }
        return blocks
    }

    /// Calls `visit(type, dataLength, first ≤80 bytes)` for each chunk after IHDR, leaving the
    /// handle positioned at the next chunk.
    private static func walkPNG(_ handle: FileHandle, visit: (String, Int, Data) -> Void) {
        guard (try? handle.seek(toOffset: 8)) != nil else { return }
        while let header = try? handle.read(upToCount: 8), header.count == 8 {
            let length = Int(UInt32(bigEndian: header.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            let start = (try? handle.offset()) ?? 0
            let peek = (try? handle.read(upToCount: min(length, 80))) ?? Data()
            visit(type, length, peek)
            guard type != "IEND", (try? handle.seek(toOffset: start + UInt64(length) + 4)) != nil else { return }
        }
    }

    /// Calls `visit(marker, segmentLength, first ≤80 bytes)` for each segment before the image data.
    private static func walkJPEG(_ handle: FileHandle, visit: (UInt8, Int, Data) -> Void) {
        guard (try? handle.seek(toOffset: 2)) != nil else { return }
        while let markerData = try? handle.read(upToCount: 2), markerData.count == 2, markerData.first == 0xFF {
            var marker = markerData.last ?? 0
            while marker == 0xFF { marker = (try? handle.read(upToCount: 1))?.first ?? 0 }
            if marker == 0xDA || marker == 0xD9 { return }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            guard let lengthData = try? handle.read(upToCount: 2), lengthData.count == 2 else { return }
            let length = Int(lengthData[0]) << 8 | Int(lengthData[1])
            guard length >= 2 else { return }
            let start = (try? handle.offset()) ?? 0
            let peek = (try? handle.read(upToCount: min(length - 2, 80))) ?? Data()
            visit(marker, length + 2, peek)
            guard (try? handle.seek(toOffset: start + UInt64(length - 2))) != nil else { return }
        }
    }

    private static func pngRemovableID(_ type: String, _ peek: Data) -> String? {
        guard let first = type.unicodeScalars.first, first.properties.isLowercase, !pngKeep.contains(type) else { return nil }
        if type == "tEXt" || type == "zTXt" || type == "iTXt" {
            let keyword = String(decoding: peek.prefix { $0 != 0 }, as: UTF8.self)
            return keyword == xmpKeyword && type == "iTXt" ? nil : "\(type):\(keyword)"
        }
        return type
    }

    private static func pngLabel(_ type: String, id: String, peek: Data) -> String {
        switch type {
        case "caBX": return "C2PA content credentials"
        case "tIME": return "Last-modified time"
        case "tEXt", "zTXt", "iTXt":
            let keyword = String(id.dropFirst(5))
            if keyword.hasPrefix("Raw profile type ") {
                let kind = keyword.dropFirst("Raw profile type ".count).lowercased()
                let name = kind == "app1" || kind == "exif" ? "EXIF" : kind.uppercased()
                return "\(name) stored as text (\(keyword))"
            }
            return "Text: \(keyword.isEmpty ? "untitled" : keyword)"
        default: return "Private chunk \(type)"
        }
    }

    /// APP3–APP12, APP15, and comments. APP0 (JFIF), APP1 (EXIF/XMP), APP2 (ICC), APP13 (IPTC),
    /// and APP14 (Adobe colour) stay: ImageIO handles them or they affect colour.
    private static func jpegRemovableID(_ marker: UInt8) -> String? {
        if marker == 0xFE { return "COM" }
        if (0xE3...0xEC).contains(marker) || marker == 0xEF { return "APP\(marker - 0xE0)" }
        return nil
    }

    private static func jpegLabel(_ marker: UInt8, peek: Data) -> String {
        if marker == 0xFE {
            let text = String(decoding: peek.prefix(40), as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            return "Comment: \(text)"
        }
        let ascii = String(decoding: peek.prefix(32), as: UTF8.self).lowercased()
        if marker == 0xEB, ascii.contains("jumb") || ascii.contains("c2pa") || peek.prefix(2) == Data("JP".utf8) {
            return "C2PA content credentials"
        }
        let identifier = String(decoding: peek.prefix { $0 >= 0x20 && $0 < 0x7F }.prefix(24), as: UTF8.self)
        return "APP\(marker - 0xE0) vendor data\(identifier.isEmpty ? "" : " (\(identifier))")"
    }

    // MARK: - Strip

    /// Removes blocks whose id is in `ids`. Returns an error message, or nil on success.
    static func strip(_ path: String, ids: Set<String>) -> String? {
        guard let format = format(path) else { return "This file has no removable embedded blocks." }
        let url = URL(fileURLWithPath: path)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).strip-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let output = FileHandle(forWritingAtPath: temp.path),
              let input = FileHandle(forReadingAtPath: path) else { return "Couldn’t create a temporary copy." }
        let copied: Bool
        switch format {
        case .png: copied = copyPNG(input, output, dropping: ids)
        case .jpeg: copied = copyJPEG(input, output, dropping: ids)
        }
        try? input.close()
        try? output.close()
        guard copied else { return "The file’s structure couldn’t be read, so nothing was changed." }
        // The copy must decode to the same picture and no longer contain what was removed.
        guard samePicture(url, temp), Set(scan(temp.path).map(\.id)).isDisjoint(with: ids) else {
            return "The cleaned copy didn’t check out, so nothing was changed."
        }
        return MetadataService.replace(url, with: temp)
    }

    private static func copyPNG(_ input: FileHandle, _ output: FileHandle, dropping ids: Set<String>) -> Bool {
        guard let signature = try? input.read(upToCount: 8), [UInt8](signature) == pngSignature else { return false }
        output.write(signature)
        var sawEnd = false
        while let header = try? input.read(upToCount: 8), header.count == 8 {
            let length = Int(UInt32(bigEndian: header.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            guard let start = try? input.offset() else { return false }
            let peek = (try? input.read(upToCount: min(length, 80))) ?? Data()
            let drop = pngRemovableID(type, peek).map(ids.contains) ?? false
            if drop {
                guard (try? input.seek(toOffset: start + UInt64(length) + 4)) != nil else { return false }
            } else {
                output.write(header)
                output.write(peek)
                guard copy(input, output, count: length - peek.count + 4) else { return false }
            }
            if type == "IEND" { sawEnd = true; break }
        }
        return sawEnd
    }

    private static func copyJPEG(_ input: FileHandle, _ output: FileHandle, dropping ids: Set<String>) -> Bool {
        guard let soi = try? input.read(upToCount: 2), soi == Data([0xFF, 0xD8]) else { return false }
        output.write(soi)
        while let markerData = try? input.read(upToCount: 2), markerData.count == 2, markerData.first == 0xFF {
            var marker = markerData.last ?? 0
            while marker == 0xFF { marker = (try? input.read(upToCount: 1))?.first ?? 0 }
            if marker == 0xDA || marker == 0xD9 {
                // Image data: copy everything that's left unchanged.
                output.write(Data([0xFF, marker]))
                while let piece = try? input.read(upToCount: pieceSize), !piece.isEmpty { output.write(piece) }
                return true
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                output.write(Data([0xFF, marker]))
                continue
            }
            guard let lengthData = try? input.read(upToCount: 2), lengthData.count == 2 else { return false }
            let length = Int(lengthData[0]) << 8 | Int(lengthData[1])
            guard length >= 2, let start = try? input.offset() else { return false }
            if let id = jpegRemovableID(marker), ids.contains(id) {
                guard (try? input.seek(toOffset: start + UInt64(length - 2))) != nil else { return false }
            } else {
                output.write(Data([0xFF, marker]))
                output.write(lengthData)
                guard copy(input, output, count: length - 2) else { return false }
            }
        }
        return false
    }

    private static func copy(_ input: FileHandle, _ output: FileHandle, count: Int) -> Bool {
        var remaining = count
        while remaining > 0 {
            guard let piece = try? input.read(upToCount: min(remaining, pieceSize)), !piece.isEmpty else { return false }
            output.write(piece)
            remaining -= piece.count
        }
        return remaining == 0
    }

    /// Same type, size, and frame count, and the cleaned copy decodes. Header reads only.
    private static func samePicture(_ original: URL, _ copy: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let a = CGImageSourceCreateWithURL(original as CFURL, options),
              let b = CGImageSourceCreateWithURL(copy as CFURL, options),
              CGImageSourceGetStatus(b) == .statusComplete,
              CGImageSourceGetType(a) == CGImageSourceGetType(b),
              CGImageSourceGetCount(a) == CGImageSourceGetCount(b),
              let pa = CGImageSourceCopyPropertiesAtIndex(a, 0, nil) as? [CFString: Any],
              let pb = CGImageSourceCopyPropertiesAtIndex(b, 0, nil) as? [CFString: Any] else { return false }
        return (pa[kCGImagePropertyPixelWidth] as? Int) == (pb[kCGImagePropertyPixelWidth] as? Int)
            && (pa[kCGImagePropertyPixelHeight] as? Int) == (pb[kCGImagePropertyPixelHeight] as? Int)
    }
}
