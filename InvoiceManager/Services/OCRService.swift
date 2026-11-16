import Foundation
import Vision
import UIKit
import PDFKit

struct OCRResult {
    var fullText: String
    var amount: Double?
    var vendor: String?
    var date: Date?
}

enum OCRService {

    static func recognize(from data: Data) async -> OCRResult {
        let image: UIImage?
        if isPDF(data), let pageImage = renderPDFFirstPage(data) {
            image = pageImage
        } else {
            image = UIImage(data: data)
        }
        guard let cgImage = image?.cgImage else {
            return OCRResult(fullText: "", amount: nil, vendor: nil, date: nil)
        }

        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                cont.resume(returning: parse(text: text))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(returning: OCRResult(fullText: "", amount: nil, vendor: nil, date: nil))
            }
        }
    }

    /// 综合：OCR + 文件名 + 邮件主题
    static func enrich(
        data: Data,
        fileName: String?,
        subject: String?
    ) async -> OCRResult {
        var result = await recognize(from: data)

        let nameSource = [fileName, subject].compactMap { $0 }.joined(separator: " ")
        let fromName = parseFileName(nameSource)

        if result.amount == nil {
            result.amount = fromName.amount
        }
        if result.amount == nil {
            result.amount = guessAmountFromText(result.fullText)
        }
        if result.vendor == nil || result.vendor?.isEmpty == true {
            result.vendor = fromName.vendor
        }
        if result.vendor == nil || isGenericName(result.vendor) {
            if let s = subject, !s.isEmpty, !isGenericName(s) {
                result.vendor = cleanVendor(s)
            } else if let f = fileName {
                result.vendor = cleanVendor(fromFileName(f))
            }
        }
        if result.date == nil, let f = fileName {
            result.date = parseDateFromName(f)
        }
        return result
    }

    static func parse(text: String) -> OCRResult {
        var amount: Double?
        var vendor: String?
        var date: Date?

        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "．", with: ".")

        let amountPatterns = [
            #"价税合计[^\d¥￥]{0,12}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"价税合计（小写）[^\d¥￥]{0,8}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"（小写）[^\d¥￥]{0,6}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"合计[（(]?小写[)）]?[^\d¥￥]{0,8}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"金额合计[^\d¥￥]{0,8}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"应付[^\d¥￥]{0,6}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"实付[^\d¥￥]{0,6}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"([¥￥]\s*\d+[.,]\d{2})"#,
            #"(\d+[.,]\d{2})\s*元"#
        ]
        for p in amountPatterns {
            if let v = firstDouble(in: normalized, pattern: p), v > 0, v < 1_000_000 {
                amount = v
                break
            }
        }
        if amount == nil {
            amount = guessAmountFromText(normalized)
        }

        let datePatterns = [
            #"(20\d{2})[年\-/\.](\d{1,2})[月\-/\.](\d{1,2})日?"#
        ]
        for p in datePatterns {
            if let d = firstDate(in: normalized, pattern: p) {
                date = d
                break
            }
        }

        let vendorPatterns = [
            #"销售方[^\n]{0,6}名称[:：]?\s*([^\n]{2,40})"#,
            #"销\s*售\s*方[:：]?\s*([^\n]{2,40})"#,
            #"开票方[:：]?\s*([^\n]{2,40})"#,
            #"商户名称[:：]?\s*([^\n]{2,40})"#,
            #"商家[:：]?\s*([^\n]{2,40})"#
        ]
        for p in vendorPatterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
               let r = Range(m.range(at: 1), in: normalized) {
                let v = String(normalized[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty && v.count <= 40 {
                    vendor = cleanVendor(v)
                    break
                }
            }
        }

        return OCRResult(fullText: text, amount: amount, vendor: vendor, date: date)
    }

    /// 从全文猜一个最像「发票金额」的数：优先带「元」的，否则取合理区间内最大的 xx.xx
    static func guessAmountFromText(_ text: String) -> Double? {
        var candidates: [Double] = []

        if let re = try? NSRegularExpression(pattern: #"(\d+[.,]\d{2})\s*元"#) {
            let range = NSRange(text.startIndex..., in: text)
            re.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                let s = String(text[r]).replacingOccurrences(of: ",", with: "")
                if let v = Double(s), v > 0, v < 100_000 { candidates.append(v) }
            }
        }

        if candidates.isEmpty,
           let re = try? NSRegularExpression(pattern: #"[¥￥]\s*(\d+[.,]\d{2})"#) {
            let range = NSRange(text.startIndex..., in: text)
            re.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                let s = String(text[r]).replacingOccurrences(of: ",", with: "")
                if let v = Double(s), v > 0, v < 100_000 { candidates.append(v) }
            }
        }

        // 退而求其次：所有 xx.xx，排除像日期的（太大的月日不太会是 .xx 金额）
        if candidates.isEmpty,
           let re = try? NSRegularExpression(pattern: #"\b(\d{1,6}[.,]\d{2})\b"#) {
            let range = NSRange(text.startIndex..., in: text)
            re.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                let s = String(text[r]).replacingOccurrences(of: ",", with: "")
                if let v = Double(s), v >= 1, v < 50_000 { candidates.append(v) }
            }
        }

        return candidates.max()
    }

    static func parseFileName(_ fileName: String) -> (amount: Double?, vendor: String?) {
        var amount: Double?
        var vendor: String?

        // 27.92元 / 27.92 元
        if let re = try? NSRegularExpression(pattern: #"(\d+[.,]\d{1,2})\s*元"#) {
            let range = NSRange(fileName.startIndex..., in: fileName)
            if let m = re.firstMatch(in: fileName, range: range),
               let r = Range(m.range(at: 1), in: fileName) {
                amount = Double(String(fileName[r]).replacingOccurrences(of: ",", with: "."))
            }
        }

        // _27.92_ 或 -27.92.
        if amount == nil,
           let re = try? NSRegularExpression(pattern: #"[_\-\s](\d+[.,]\d{2})[_\-\s\.]"#) {
            let range = NSRange(fileName.startIndex..., in: fileName)
            if let m = re.firstMatch(in: fileName, range: range),
               let r = Range(m.range(at: 1), in: fileName) {
                let v = Double(String(fileName[r]).replacingOccurrences(of: ",", with: "."))
                if let v, v > 0, v < 100_000 { amount = v }
            }
        }

        // 【滴滴出行-xxx】 / 【365约车...】
        if let s = fileName.firstIndex(of: "【"),
           let e = fileName.firstIndex(of: "】"),
           s < e {
            let inner = String(fileName[fileName.index(after: s)..<e])
            if let dash = inner.firstIndex(of: "-") {
                vendor = String(inner[..<dash]).trimmingCharacters(in: .whitespaces)
            } else {
                vendor = inner.trimmingCharacters(in: .whitespaces)
            }
        }

        // 电子发票_商家名_...
        if vendor == nil {
            let parts = fileName
                .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".PDF", with: "")
                .components(separatedBy: CharacterSet(charactersIn: "_—-"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isGenericName($0) && $0.count >= 2 }
            // 跳过「电子发票」「发票」等
            if let first = parts.first(where: { !isGenericName($0) && !$0.allSatisfy(\.isNumber) }) {
                vendor = cleanVendor(first)
            }
        }

        return (amount, vendor)
    }

    // MARK: - helpers

    static func isGenericName(_ s: String?) -> Bool {
        guard let s else { return true }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ban = ["invoice", "pdf", "image", "img", "untitled", "附件", "电子发票", "发票",
                   "scan", "document", "doc", "file", "附件1", "未命名"]
        return t.isEmpty || ban.contains(t) || t.hasPrefix("invoice")
    }

    static func cleanVendor(_ s: String) -> String {
        var v = s
        for prefix in ["电子发票", "发票", "附件"] {
            if v.hasPrefix(prefix) {
                v = String(v.dropFirst(prefix.count))
            }
        }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "_-— "))
        if v.count > 24 {
            v = String(v.prefix(24))
        }
        return v.isEmpty ? s : v
    }

    static func fromFileName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return cleanVendor(base)
    }

    static func parseDateFromName(_ name: String) -> Date? {
        if let re = try? NSRegularExpression(pattern: #"(20\d{2})[\-年/.]?(\d{1,2})[\-月/.]?(\d{1,2})"#),
           let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           m.numberOfRanges >= 4,
           let yR = Range(m.range(at: 1), in: name),
           let moR = Range(m.range(at: 2), in: name),
           let dR = Range(m.range(at: 3), in: name),
           let y = Int(name[yR]), let mo = Int(name[moR]), let d = Int(name[dR]) {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = d
            return Calendar.current.date(from: c)
        }
        return nil
    }

    private static func firstDouble(in text: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        var s = String(text[r])
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Double(s)
    }

    private static func firstDate(in text: String, pattern: String) -> Date? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges >= 4,
              let yR = Range(m.range(at: 1), in: text),
              let moR = Range(m.range(at: 2), in: text),
              let dR = Range(m.range(at: 3), in: text),
              let y = Int(text[yR]), let mo = Int(text[moR]), let d = Int(text[dR]) else { return nil }
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d
        return Calendar.current.date(from: c)
    }

    private static func isPDF(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46
    }

    private static func renderPDFFirstPage(_ data: Data) -> UIImage? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let rect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }
}
