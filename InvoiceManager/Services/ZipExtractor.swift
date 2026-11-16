import Foundation
import Compression

/// 极简 ZIP 解压：支持 Store / Deflate，用于邮件里的发票压缩包
enum ZipExtractor {

    static func extractFiles(from data: Data) -> [(name: String, data: Data)] {
        guard data.count > 30, data[0] == 0x50, data[1] == 0x4B else { return [] }

        var results: [(String, Data)] = []
        var offset = 0

        while offset + 30 <= data.count {
            guard data[offset] == 0x50, data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x03, data[offset + 3] == 0x04 else {
                break
            }

            let compression = readUInt16(data, offset + 8)
            let compSize = Int(readUInt32(data, offset + 18))
            let uncompSize = Int(readUInt32(data, offset + 22))
            let nameLen = Int(readUInt16(data, offset + 26))
            let extraLen = Int(readUInt16(data, offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen + compSize <= data.count else { break }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "file"

            let dataStart = nameEnd + extraLen
            let dataEnd = dataStart + compSize
            let compressed = data.subdata(in: dataStart..<dataEnd)

            if name.hasSuffix("/") {
                offset = dataEnd
                continue
            }

            let payload: Data?
            if compression == 0 {
                payload = compressed
            } else if compression == 8 {
                payload = inflate(compressed, expectedSize: uncompSize)
            } else {
                payload = nil
            }

            if let payload, !payload.isEmpty {
                results.append((name, payload))
            }

            offset = dataEnd
        }
        return results
    }

    /// 从 ZIP 里只抽出「电子发票」类 PDF（排除行程单）
    static func extractInvoicePDFs(from zipData: Data) -> [(name: String, data: Data)] {
        extractFiles(from: zipData).compactMap { item in
            let lower = item.name.lowercased()
            guard lower.hasSuffix(".pdf") else { return nil }
            if InvoiceFileFilter.isItinerary(item.name) { return nil }
            guard item.data.count > 4,
                  item.data[0] == 0x25, item.data[1] == 0x50 else { return nil }
            if InvoiceFileFilter.isInvoice(item.name) || item.data.count > 1000 {
                return item
            }
            return nil
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// ZIP deflate 多为 raw；尝试直接 zlib / 加假 header 再解
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        let dstSize = max(expectedSize, input.count * 8, 128 * 1024)

        if let out = decodeZlib(input, dstSize: dstSize), !out.isEmpty {
            return out
        }

        var wrapped = Data([0x78, 0x01])
        wrapped.append(input)
        if let out = decodeZlib(wrapped, dstSize: dstSize), !out.isEmpty {
            return out
        }

        var wrapped2 = Data([0x78, 0x9C])
        wrapped2.append(input)
        if let out = decodeZlib(wrapped2, dstSize: dstSize), !out.isEmpty {
            return out
        }

        return nil
    }

    private static func decodeZlib(_ input: Data, dstSize: Int) -> Data? {
        var dest = Data(count: dstSize)
        let n: Int = dest.withUnsafeMutableBytes { destPtr in
            input.withUnsafeBytes { srcPtr in
                guard let src = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    dst, dstSize,
                    src, input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard n > 0 else { return nil }
        dest.count = n
        return dest
    }
}

enum InvoiceFileFilter {
    static func isItinerary(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("行程单") { return true }
        if n.contains("电子行程") { return true }
        if n.contains("行程") && !n.contains("发票") { return true }
        return false
    }

    static func isInvoice(_ name: String) -> Bool {
        let n = name
        if n.contains("行程单") { return false }
        if n.contains("电子发票") { return true }
        if n.contains("发票") && !n.contains("行程") { return true }
        return false
    }

    static func shouldImport(fileName: String) -> Bool {
        if isItinerary(fileName) { return false }
        let lower = fileName.lowercased()
        if lower.hasSuffix(".pdf") { return true }
        if lower.hasSuffix(".zip") { return true }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") {
            return true
        }
        return false
    }
}
