import Foundation
import Compression

/// 极简 ZIP 解压：支持 Store / Deflate，用于邮件里的发票压缩包
enum ZipExtractor {

    static func extractFiles(from data: Data) -> [(name: String, data: Data)] {
        guard data.count > 30, data[0] == 0x50, data[1] == 0x4B else { return [] } // PK

        var results: [(String, Data)] = []
        var offset = 0

        while offset + 30 <= data.count {
            // Local file header signature 0x04034b50
            guard data[offset] == 0x50, data[offset+1] == 0x4B,
                  data[offset+2] == 0x03, data[offset+3] == 0x04 else {
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

            // 跳过目录项
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
            if InvoiceFileFilter.isInvoice(item.name) || item.data.count > 1000 {
                // 校验 PDF 头
                guard item.data.count > 4,
                      item.data[0] == 0x25, item.data[1] == 0x50 else { return nil }
                return item
            }
            return nil
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset+1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset+1]) << 8)
            | (UInt32(data[offset+2]) << 16)
            | (UInt32(data[offset+3]) << 24)
    }

    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        let dstSize = max(expectedSize, input.count * 4, 64 * 1024)
        var dest = Data(count: dstSize)
        let result: Int = dest.withUnsafeMutableBytes { destPtr in
            input.withUnsafeBytes { srcPtr in
                guard let src = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destPtr.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(
                    dst, dstSize,
                    src, input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        // ZIP deflate 是 raw deflate，COMPRESSION_ZLIB 可能要试 COMPRESSION_ZLIB 带 header
        // 若失败再试 raw：Apple 的 COMPRESSION_ZLIB 期望 zlib wrapper；ZIP 用 raw deflate
        if result <= 0 {
            return inflateRaw(input, expectedSize: expectedSize)
        }
        dest.count = result
        return dest
    }

    /// ZIP 的 deflate 是 raw（无 zlib header），用 stream 解码
    private static func inflateRaw(_ input: Data, expectedSize: Int) -> Data? {
        let dstCapacity = max(expectedSize, input.count * 8, 128 * 1024)
        var dest = Data(count: dstCapacity)

        let status: Int = dest.withUnsafeMutableBytes { destBuf in
            input.withUnsafeBytes { srcBuf in
                guard let srcBase = srcBuf.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = destBuf.bindMemory(to: UInt8.self).baseAddress else { return -1 }

                // 手动加 zlib header 再解，或用 compression_stream
                var stream = compression_stream()
                var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                guard status != COMPRESSION_STATUS_ERROR else { return -1 }
                defer { compression_stream_destroy(&stream) }

                stream.src_ptr = srcBase
                stream.src_size = input.count
                stream.dst_ptr = dstBase
                stream.dst_size = dstCapacity

                // 先试 zlib；失败时许多 ZIP 需要 raw — 用 FILTER
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_ERROR {
                    return -1
                }
                return dstCapacity - stream.dst_size
            }
        }

        if status > 0 {
            dest.count = status
            return dest
        }

        // Fallback：给 raw deflate 包一层假 zlib header 再解
        var wrapped = Data([0x78, 0x01]) // zlib header
        wrapped.append(input)
        // Adler32 可省略，有的实现仍能解
        let dstSize2 = max(expectedSize, input.count * 8, 128 * 1024)
        var dest2 = Data(count: dstSize2)
        let n = dest2.withUnsafeMutableBytes { dp in
            wrapped.withUnsafeBytes { sp -> Int in
                guard let s = sp.bindMemory(to: UInt8.self).baseAddress,
                      let d = dp.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(d, dstSize2, s, wrapped.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n > 0 {
            dest2.count = n
            return dest2
        }
        return nil
    }
}

enum InvoiceFileFilter {
    /// 行程单 / 行程 —— 不要
    static func isItinerary(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("行程单") { return true }
        if n.contains("电子行程") { return true }
        // 「行程」但不含「发票」
        if n.contains("行程") && !n.contains("发票") { return true }
        return false
    }

    /// 明确是发票
    static func isInvoice(_ name: String) -> Bool {
        let n = name
        if n.contains("行程单") { return false }
        if n.contains("电子发票") { return true }
        if n.contains("发票") && !n.contains("行程") { return true }
        return false
    }

    /// 是否应导入这个附件名
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
