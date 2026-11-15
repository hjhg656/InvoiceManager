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
        // PDF → 第一页图；图片直接用
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

    static func parse(text: String) -> OCRResult {
        var amount: Double?
        var vendor: String?
        var date: Date?

        // 金额：优先「价税合计」「合计」「金额」附近的数字
        let amountPatterns = [
            #"价税合计[^\d]{0,8}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"合计[^\d]{0,8}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"金额[^\d]{0,8}([¥￥]?\s*\d+[.,]\d{2})"#,
            #"([¥￥]\s*\d+[.,]\d{2})"#,
            #"(\d+[.,]\d{2})\s*元"#
        ]
        for p in amountPatterns {
            if let v = firstDouble(in: text, pattern: p) {
                amount = v
                break
            }
        }

        // 日期 yyyy-MM-dd / yyyy年M月d日
        let datePatterns = [
            #"(20\d{2})[年\-/\.年](\d{1,2})[月\-/\.月](\d{1,2})日?"#
        ]
        for p in datePatterns {
            if let d = firstDate(in: text, pattern: p) {
                date = d
                break
            }
        }

        // 销售方 / 商家名称粗提取
        let vendorPatterns = [
            #"销售方[^\n]{0,4}名称[:：]?\s*([^\n]{2,30})"#,
            #"名称[:：]\s*([^\n]{2,30})"#
        ]
        for p in vendorPatterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                vendor = String(text[r]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return OCRResult(fullText: text, amount: amount, vendor: vendor, date: date)
    }

    // 也用于文件名
    static func parseFileName(_ fileName: String) -> (amount: Double?, vendor: String?) {
        var amount: Double?
        var vendor: String?
        if let re = try? NSRegularExpression(pattern: #"(\d+\.\d{1,2})\s*元"#) {
            let range = NSRange(fileName.startIndex..., in: fileName)
            if let m = re.firstMatch(in: fileName, range: range),
               let r = Range(m.range(at: 1), in: fileName) {
                amount = Double(fileName[r])
            }
        }
        if let s = fileName.firstIndex(of: "【"),
           let e = fileName.firstIndex(of: "】") {
            let inner = String(fileName[fileName.index(after: s)..<e])
            if let dash = inner.firstIndex(of: "-") {
                vendor = String(inner[..<dash])
                    .replacingOccurrences(of: "特选", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                vendor = inner
            }
        }
        return (amount, vendor)
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
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: " ", with: "")
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
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
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
