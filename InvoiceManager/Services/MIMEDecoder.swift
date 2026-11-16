import Foundation

enum MIMEDecoder {

    /// 解码邮件头里的 =?UTF-8?B?...?= / =?UTF-8?Q?...?=
    static func decodeEncodedWords(_ raw: String) -> String {
        var result = raw
        // 可能有多段 encoded-word
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return decodeQuotedPrintableString(raw)
        }

        let matches = re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        // 从后往前替换，避免 range 错位
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let charsetR = Range(match.range(at: 1), in: raw),
                  let encodingR = Range(match.range(at: 2), in: raw),
                  let dataR = Range(match.range(at: 3), in: raw),
                  let fullR = Range(match.range(at: 0), in: raw) else { continue }

            let charset = String(raw[charsetR]).uppercased()
            let encoding = String(raw[encodingR]).uppercased()
            let payload = String(raw[dataR])

            let decoded: String?
            if encoding == "B" {
                // base64，可能含空格
                let cleaned = payload.replacingOccurrences(of: " ", with: "")
                if let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) {
                    decoded = string(from: data, charset: charset)
                } else {
                    decoded = nil
                }
            } else {
                // Q encoding
                let qp = payload.replacingOccurrences(of: "_", with: " ")
                if let data = decodeQuotedPrintableData(qp) {
                    decoded = string(from: data, charset: charset)
                } else {
                    decoded = nil
                }
            }

            if let decoded {
                result.replaceSubrange(fullR, with: decoded)
            }
        }

        // 再处理裸 =XX=YY
        if result.contains("=") {
            result = decodeQuotedPrintableString(result)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func string(from data: Data, charset: String) -> String? {
        let cs = charset.uppercased()
        if cs.contains("UTF-8") || cs.contains("UTF8") {
            return String(data: data, encoding: .utf8)
        }
        if cs.contains("GB") || cs.contains("2312") || cs.contains("18030") {
            // CFString 转码
            let cfenc = CFStringConvertWindowsCodepageToEncoding(936) // GBK
            let nsenc = CFStringConvertEncodingToNSStringEncoding(cfenc)
            return String(data: data, encoding: String.Encoding(rawValue: nsenc))
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func decodeQuotedPrintableString(_ s: String) -> String {
        guard let data = decodeQuotedPrintableData(s) else { return s }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? s
    }

    static func decodeQuotedPrintableData(_ s: String) -> Data? {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 61, i + 2 < bytes.count { // '='
                let h1 = bytes[i + 1]
                let h2 = bytes[i + 2]
                // soft line break =

                if h1 == 13 || h1 == 10 {
                    i += 2
                    if h1 == 13, i < bytes.count, bytes[i] == 10 { i += 1 }
                    continue
                }
                let hex = String(bytes: [h1, h2], encoding: .ascii) ?? ""
                if let b = UInt8(hex, radix: 16) {
                    out.append(b)
                    i += 3
                    continue
                }
            }
            if bytes[i] == 13 || bytes[i] == 10 {
                i += 1
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }

    /// 从主题推断商家
    static func vendorFromSubject(_ subject: String) -> String? {
        let s = subject
        if s.contains("高德") { return "高德打车" }
        if s.contains("滴滴") { return "滴滴出行" }
        if s.contains("曹操") { return "曹操出行" }
        if s.contains("T3") || s.contains("t3") { return "T3出行" }
        if s.contains("美团") { return "美团" }
        if s.contains("携程") { return "携程" }
        if s.contains("飞猪") { return "飞猪" }
        if s.contains("铁路") || s.contains("12306") { return "铁路12306" }
        if s.contains("电子发票") {
            // 「xxx电子发票」取前面
            if let r = s.range(of: "电子发票") {
                let prefix = String(s[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.count >= 2 { return prefix }
            }
            return "电子发票"
        }
        return nil
    }
}
