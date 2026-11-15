import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    @State private var showAdd = false
    @State private var searchText = ""
    @State private var showExport = false
    @State private var exportURL: URL?

    private var filtered: [Invoice] {
        guard !searchText.isEmpty else { return invoices }
        let q = searchText.lowercased()
        return invoices.filter {
            $0.vendor.lowercased().contains(q)
                || $0.notes.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
                || String(format: "%.2f", $0.amount).contains(q)
        }
    }

    private var groups: [(key: String, title: String, items: [Invoice], total: Double)] {
        let dict = Dictionary(grouping: filtered, by: \.monthKey)
        return dict.keys.sorted(by: >).compactMap { key in
            guard let items = dict[key] else { return nil }
            let sorted = items.sorted { $0.date > $1.date }
            let total = sorted.reduce(0.0) { $0 + $1.amount }
            return (key, sorted.first?.monthTitle ?? key, sorted, total)
        }
    }

    private var grandTotal: Double {
        filtered.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    ContentUnavailableView {
                        Label("还没有发票", systemImage: "doc.text")
                    } description: {
                        Text("点右上角 + 添加。支持手动填写、拍照，或一次导入多张电子发票 PDF。")
                    } actions: {
                        Button("添加发票") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("合计")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "¥%.2f", grandTotal))
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                Text("\(filtered.count) / \(invoices.count) 张")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        ForEach(groups, id: \.key) { group in
                            Section {
                                ForEach(group.items, id: \.id) { inv in
                                    NavigationLink {
                                        InvoiceDetailView(invoice: inv)
                                    } label: {
                                        InvoiceRow(invoice: inv)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            modelContext.delete(inv)
                                            try? modelContext.save()
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.title)
                                    Spacer()
                                    Text(String(format: "¥%.2f", group.total))
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("发票")
            .searchable(text: $searchText, prompt: "搜索商家、金额、备注")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !invoices.isEmpty {
                        Menu {
                            Button {
                                exportCSV()
                            } label: {
                                Label("导出 CSV 表格", systemImage: "tablecells")
                            }
                            Button {
                                exportAttachments()
                            } label: {
                                Label("导出全部附件", systemImage: "doc.on.doc")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddInvoiceView()
            }
            .sheet(isPresented: $showExport) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
        }
    }

    // MARK: - 导出 CSV

    private func exportCSV() {
        var lines = ["日期,商家,分类,金额,备注,来源"]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        for inv in invoices.sorted(by: { $0.date > $1.date }) {
            let row = [
                df.string(from: inv.date),
                csvEscape(inv.vendor),
                csvEscape(inv.category),
                String(format: "%.2f", inv.amount),
                csvEscape(inv.notes),
                inv.source
            ].joined(separator: ",")
            lines.append(row)
        }
        let csv = lines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票导出-\(Int(Date().timeIntervalSince1970)).csv")
        do {
            try csv.data(using: .utf8)?.write(to: url)
            exportURL = url
            showExport = true
        } catch {
            print("CSV export failed: \(error)")
        }
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: - 导出附件（打包到临时目录后分享）

    private func exportAttachments() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票附件-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var count = 0
        for inv in invoices {
            guard let data = inv.imageData else { continue }
            let name: String
            if let fn = inv.fileName, !fn.isEmpty {
                name = fn
            } else if data.count > 4 && data[0] == 0x25 && data[1] == 0x50 { // %PDF
                name = "\(inv.vendor.isEmpty ? "发票" : inv.vendor)-\(String(format: "%.2f", inv.amount)).pdf"
            } else {
                name = "\(inv.vendor.isEmpty ? "发票" : inv.vendor)-\(String(format: "%.2f", inv.amount)).jpg"
            }
            let safe = name.replacingOccurrences(of: "/", with: "-")
            let fileURL = dir.appendingPathComponent(safe)
            try? data.write(to: fileURL)
            count += 1
        }

        guard count > 0 else { return }
        exportURL = dir
        showExport = true
    }
}

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 44, height: 44)
                if let data = invoice.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: invoice.imageData != nil ? "doc.richtext" : "doc.text")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.vendor.isEmpty ? "未填商家" : invoice.vendor)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(invoice.category)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    Text(invoice.date, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(String(format: "¥%.2f", invoice.amount))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 2)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
        .modelContainer(for: Invoice.self, inMemory: true)
}
