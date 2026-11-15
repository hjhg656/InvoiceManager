import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    @State private var showAdd = false
    @State private var searchText = ""
    @State private var filterStatus: InvoiceStatus?
    @State private var filterKind: InvoiceKind?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var showRestore = false
    @State private var toast: String?

    private var filtered: [Invoice] {
        invoices.filter { inv in
            if let filterStatus, inv.status != filterStatus { return false }
            if let filterKind, inv.kind != filterKind { return false }
            if searchText.isEmpty { return true }
            let q = searchText.lowercased()
            return inv.vendor.lowercased().contains(q)
                || inv.notes.lowercased().contains(q)
                || inv.kind.rawValue.contains(q)
                || inv.status.rawValue.contains(q)
                || String(format: "%.2f", inv.amount).contains(q)
        }
    }

    private var groups: [(key: String, title: String, items: [Invoice], total: Double)] {
        let dict = Dictionary(grouping: filtered, by: \.monthKey)
        return dict.keys.sorted(by: >).compactMap { key in
            guard let items = dict[key] else { return nil }
            let sorted = items.sorted { $0.date > $1.date }
            return (key, sorted.first?.monthTitle ?? key, sorted, sorted.reduce(0) { $0 + $1.amount })
        }
    }

    private var totalAmount: Double { filtered.reduce(0) { $0 + $1.amount } }
    private var pendingAmount: Double {
        filtered.filter { $0.status == .pending }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    ContentUnavailableView {
                        Label("还没有发票", systemImage: "doc.text")
                    } description: {
                        Text("支持拍照、相册、PDF 导入，OCR 识别金额后可手动修改。")
                    } actions: {
                        Button("添加发票") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        statsSection
                        filterSection
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
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            inv.status = .submitted
                                            try? modelContext.save()
                                        } label: {
                                            Label("已上交", systemImage: "checkmark.circle")
                                        }
                                        .tint(.blue)
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
            .navigationTitle("发票台账")
            .searchable(text: $searchText, prompt: "搜索商家、金额、状态")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { share(ExportService.makeCSV(invoices: filtered)) } label: {
                            Label("导出 Excel(CSV)", systemImage: "tablecells")
                        }
                        Button { share(ExportService.makeAttachmentsFolder(invoices: filtered)) } label: {
                            Label("导出附件文件夹", systemImage: "folder")
                        }
                        Button { share(ExportService.makeFinancePackage(invoices: filtered)) } label: {
                            Label("打包给财务(表+附件)", systemImage: "briefcase")
                        }
                        Divider()
                        Button { share(ExportService.makeBackup(invoices: invoices)) } label: {
                            Label("备份全部数据", systemImage: "externaldrive")
                        }
                        Button { showRestore = true } label: {
                            Label("从备份恢复", systemImage: "arrow.clockwise.icloud")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddInvoiceView()
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
            .fileImporter(
                isPresented: $showRestore,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                restore(result)
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var statsSection: some View {
        Section("统计（当前筛选）") {
            HStack {
                VStack(alignment: .leading) {
                    Text("合计").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "¥%.2f", totalAmount))
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("待提交").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "¥%.2f", pendingAmount))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            Text("\(filtered.count) 张发票")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("全部状态", selected: filterStatus == nil) { filterStatus = nil }
                    ForEach(InvoiceStatus.allCases) { s in
                        filterChip(s.rawValue, selected: filterStatus == s) {
                            filterStatus = (filterStatus == s) ? nil : s
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("全部票种", selected: filterKind == nil) { filterKind = nil }
                    ForEach(InvoiceKind.allCases) { k in
                        filterChip(k.rawValue, selected: filterKind == k) {
                            filterKind = (filterKind == k) ? nil : k
                        }
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func share(_ url: URL?) {
        guard let url else {
            showToast("没有可导出的内容（可能缺少附件）")
            return
        }
        // 分享文件夹时，收集里面的文件更可靠
        var items: [Any] = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                // 若有子目录「附件」，也展开
                for f in files {
                    var subDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: f.path, isDirectory: &subDir), subDir.boolValue {
                        if let nested = try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil) {
                            items.append(contentsOf: nested)
                        }
                    } else {
                        items.append(f)
                    }
                }
            }
        } else {
            items = [url]
        }
        if items.isEmpty {
            showToast("导出内容为空")
            return
        }
        shareItems = items
        showShare = true
    }

    private func restore(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let n = try ExportService.restoreBackup(from: url, into: modelContext)
            showToast("已恢复 \(n) 条发票")
        } catch {
            showToast("恢复失败：\(error.localizedDescription)")
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toast = nil }
        }
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
                    Text(invoice.kind.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    Text(invoice.status.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(statusColor)
                    Text(invoice.date, format: .dateTime.month().day())
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

    private var statusColor: Color {
        switch invoice.status {
        case .pending: return .orange
        case .submitted: return .blue
        case .reimbursed: return .green
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
