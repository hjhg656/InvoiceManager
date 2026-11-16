import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let title: String
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \ExpenseBatch.createdAt, order: .reverse) private var batches: [ExpenseBatch]

    @State private var showAdd = false
    @State private var showEmailImport = false
    @State private var searchText = ""
    @State private var filterStatus: InvoiceStatus?
    @State private var filterKind: InvoiceKind?
    @State private var sharePayload: SharePayload?
    @State private var showRestore = false
    @State private var toast: String?
    @State private var selectedIds: Set<UUID> = []
    @State private var isSelecting = false
    @State private var showBatchNameAlert = false
    @State private var batchName = ""
    @State private var showBatches = false

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
    private var selectedInvoices: [Invoice] {
        invoices.filter { selectedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    ContentUnavailableView {
                        Label("还没有发票", systemImage: "doc.text")
                    } description: {
                        Text("支持拍照、相册、PDF，或从邮箱 IMAP 拉取附件。")
                    } actions: {
                        Button("添加发票") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                        Button("从邮箱导入") { showEmailImport = true }
                    }
                } else {
                    List {
                        if !isSelecting {
                            statsSection
                            filterSection
                            if !batches.isEmpty {
                                batchEntrySection
                            }
                        } else {
                            Section {
                                Text("已选 \(selectedIds.count) 张，合计 ¥\(String(format: "%.2f", selectedInvoices.reduce(0) { $0 + $1.amount }))")
                                    .font(.subheadline)
                            }
                        }

                        ForEach(groups, id: \.key) { group in
                            Section {
                                ForEach(group.items, id: \.id) { inv in
                                    invoiceRow(inv)
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
            .toolbar { toolbarContent }
            .sheet(isPresented: $showAdd) { AddInvoiceView() }
            .sheet(isPresented: $showEmailImport) { EmailImportView() }
            .sheet(item: $sharePayload) { ActivityView(activityItems: $0.urls) }
            .sheet(isPresented: $showBatches) { BatchListView() }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json], allowsMultipleSelection: false) { restore($0) }
            .alert("新建报销批次", isPresented: $showBatchNameAlert) {
                TextField("例如：11月出差", text: $batchName)
                Button("取消", role: .cancel) {}
                Button("创建") { createBatch() }
            } message: {
                Text("将把选中的 \(selectedIds.count) 张发票打成一批，并标记为已上交")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            .onAppear {
                let n = InboxImporter.importPending(into: modelContext)
                if n > 0 { showToast("从分享导入 \(n) 张发票") }
            }
        }
    }

    @ViewBuilder
    private func invoiceRow(_ inv: Invoice) -> some View {
        if isSelecting {
            HStack {
                Image(systemName: selectedIds.contains(inv.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIds.contains(inv.id) ? Color.accentColor : .secondary)
                InvoiceRow(invoice: inv)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selectedIds.contains(inv.id) { selectedIds.remove(inv.id) }
                else { selectedIds.insert(inv.id) }
            }
        } else {
            NavigationLink {
                InvoiceDetailView(invoice: inv)
            } label: {
                InvoiceRow(invoice: inv)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    modelContext.delete(inv)
                    try? modelContext.save()
                } label: { Label("删除", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button {
                    inv.statusRaw = InvoiceStatus.submitted.rawValue
                    try? modelContext.save()
                } label: { Label("已上交", systemImage: "checkmark.circle") }
                .tint(.blue)
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
            Text("\(filtered.count) 张发票 · \(batches.count) 个批次")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("全部状态", on: filterStatus == nil) { filterStatus = nil }
                    ForEach(InvoiceStatus.allCases) { s in
                        chip(s.rawValue, on: filterStatus == s) {
                            filterStatus = filterStatus == s ? nil : s
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("全部票种", on: filterKind == nil) { filterKind = nil }
                    ForEach(InvoiceKind.allCases) { k in
                        chip(k.rawValue, on: filterKind == k) {
                            filterKind = filterKind == k ? nil : k
                        }
                    }
                }
            }
        }
    }

    private var batchEntrySection: some View {
        Section("报销批次") {
            Button { showBatches = true } label: {
                HStack {
                    Label("查看全部批次", systemImage: "folder")
                    Spacer()
                    Text("\(batches.count)").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button("取消") {
                    isSelecting = false
                    selectedIds.removeAll()
                }
            } else {
                Menu {
                    Button { showEmailImport = true } label: {
                        Label("从邮箱导入", systemImage: "envelope.badge")
                    }
                    Divider()
                    Button { exportCSV() } label: { Label("导出 Excel (CSV)", systemImage: "tablecells") }
                    Button { exportAttachments() } label: { Label("导出附件", systemImage: "doc.on.doc") }
                    Button { exportFinancePackage() } label: { Label("打包给财务", systemImage: "briefcase") }
                    Divider()
                    Button { exportBackup() } label: { Label("备份全部数据", systemImage: "externaldrive") }
                    Button { showRestore = true } label: { Label("从备份恢复", systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Menu {
                    Button("标为待提交") { batchSetStatus(.pending) }
                    Button("标为已上交") { batchSetStatus(.submitted) }
                    Button("标为已报销") { batchSetStatus(.reimbursed) }
                    Divider()
                    Button("打成报销批次…") {
                        batchName = defaultBatchName()
                        showBatchNameAlert = true
                    }
                    .disabled(selectedIds.isEmpty)
                    Divider()
                    Button("删除所选", role: .destructive) { batchDelete() }
                } label: {
                    Text("操作")
                }
                .disabled(selectedIds.isEmpty)
            } else {
                Button { isSelecting = true } label: {
                    Image(systemName: "checkmark.circle")
                }
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func batchSetStatus(_ status: InvoiceStatus) {
        for inv in selectedInvoices { inv.statusRaw = status.rawValue }
        try? modelContext.save()
        showToast("已将 \(selectedIds.count) 张标为「\(status.rawValue)」")
        isSelecting = false
        selectedIds.removeAll()
    }

    private func batchDelete() {
        for inv in selectedInvoices { modelContext.delete(inv) }
        try? modelContext.save()
        showToast("已删除 \(selectedIds.count) 张")
        isSelecting = false
        selectedIds.removeAll()
    }

    private func defaultBatchName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日报销"
        return f.string(from: Date())
    }

    private func createBatch() {
        let name = batchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !selectedIds.isEmpty else { return }
        let batch = ExpenseBatch(name: name)
        modelContext.insert(batch)
        for inv in selectedInvoices {
            inv.batch = batch
            inv.statusRaw = InvoiceStatus.submitted.rawValue
        }
        try? modelContext.save()
        showToast("已创建批次「\(name)」· \(selectedIds.count) 张")
        isSelecting = false
        selectedIds.removeAll()
        batchName = ""
    }

    private func exportCSV() {
        guard let url = ExportService.makeCSV(invoices: filtered),
              FileManager.default.fileExists(atPath: url.path) else {
            showToast("导出失败"); return
        }
        sharePayload = SharePayload(urls: [url], title: "CSV")
    }

    private func exportAttachments() {
        let urls = ExportService.attachmentFileURLs(invoices: filtered)
        if urls.isEmpty { showToast("没有可导出的附件"); return }
        sharePayload = SharePayload(urls: urls, title: "附件")
    }

    private func exportFinancePackage() {
        var urls: [URL] = []
        if let csv = ExportService.makeCSV(invoices: filtered) { urls.append(csv) }
        urls.append(contentsOf: ExportService.attachmentFileURLs(invoices: filtered))
        if urls.isEmpty { showToast("没有可导出的内容"); return }
        sharePayload = SharePayload(urls: urls, title: "财务包")
    }

    private func exportBackup() {
        guard let url = ExportService.makeBackup(invoices: invoices) else {
            showToast("备份失败"); return
        }
        sharePayload = SharePayload(urls: [url], title: "备份")
    }

    private func restore(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let n = try ExportService.restoreBackup(from: url, into: modelContext)
            showToast("已恢复 \(n) 条")
        } catch {
            showToast("恢复失败：\(error.localizedDescription)")
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { toast = nil }
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
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: invoice.imageData != nil ? "doc.richtext" : "doc.text")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.vendor.isEmpty ? "未填商家" : invoice.vendor)
                    .font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(invoice.kind.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    Text(invoice.status.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(statusColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(statusColor)
                    if invoice.batch != nil {
                        Image(systemName: "folder.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(invoice.date, format: .dateTime.month().day())
                        .font(.caption).foregroundStyle(.secondary)
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

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let existing = activityItems.filter { FileManager.default.fileExists(atPath: $0.path) }
        return UIActivityViewController(activityItems: existing, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
