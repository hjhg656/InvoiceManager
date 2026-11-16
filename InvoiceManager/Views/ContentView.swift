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
    @State private var filterMonthKey: String? = nil  // nil = 全部月份
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
            if let filterMonthKey, inv.monthKey != filterMonthKey { return false }
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

    /// 所有出现过的月份（倒序）
    private var allMonthOptions: [(key: String, title: String, count: Int, total: Double)] {
        let dict = Dictionary(grouping: invoices, by: \.monthKey)
        return dict.keys.sorted(by: >).compactMap { key in
            guard let items = dict[key], !items.isEmpty else { return nil }
            let title = items.first?.monthTitle ?? key
            let total = items.reduce(0.0) { $0 + $1.amount }
            return (key, title, items.count, total)
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
    private var allFilteredIds: Set<UUID> {
        Set(filtered.map(\.id))
    }
    private var isAllSelected: Bool {
        !filtered.isEmpty && allFilteredIds.isSubset(of: selectedIds)
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
                        if isSelecting {
                            selectionHeader
                        } else {
                            statsSection
                            monthJumpSection
                            filterSection
                            if !batches.isEmpty {
                                batchEntrySection
                            }
                        }

                        ForEach(groups, id: \.key) { group in
                            Section {
                                ForEach(group.items, id: \.id) { inv in
                                    invoiceRow(inv)
                                }
                            } header: {
                                monthSectionHeader(group)
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
                // 默认定位到最新月份，减少滑动
                if filterMonthKey == nil, let latest = allMonthOptions.first?.key {
                    filterMonthKey = latest
                }
            }
        }
    }

    // MARK: - Selection header

    private var selectionHeader: some View {
        Section {
            HStack {
                Text("已选 \(selectedIds.count) 张")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "¥%.2f", selectedInvoices.reduce(0) { $0 + $1.amount }))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button {
                    if isAllSelected {
                        selectedIds.subtract(allFilteredIds)
                    } else {
                        selectedIds.formUnion(allFilteredIds)
                    }
                } label: {
                    Label(
                        isAllSelected ? "取消全选" : "全选当前列表",
                        systemImage: isAllSelected ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.subheadline)
                }
                Spacer()
                if filterMonthKey != nil {
                    Text("仅当前月份")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Month jump

    private var monthJumpSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    monthChip("全部", on: filterMonthKey == nil, subtitle: "\(invoices.count)张") {
                        filterMonthKey = nil
                    }
                    ForEach(allMonthOptions, id: \.key) { m in
                        monthChip(
                            m.title,
                            on: filterMonthKey == m.key,
                            subtitle: String(format: "¥%.0f", m.total)
                        ) {
                            filterMonthKey = filterMonthKey == m.key ? nil : m.key
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("按月查看")
        }
    }

    private func monthChip(_ title: String, on: Bool, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .opacity(0.85)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func monthSectionHeader(_ group: (key: String, title: String, items: [Invoice], total: Double)) -> some View {
        HStack {
            Text(group.title)
                .font(.subheadline.weight(.semibold))
            Text("\(group.items.count) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "¥%.2f", group.total))
                .font(.subheadline.monospacedDigit().weight(.medium))
            if isSelecting {
                Button {
                    let ids = Set(group.items.map(\.id))
                    if ids.isSubset(of: selectedIds) {
                        selectedIds.subtract(ids)
                    } else {
                        selectedIds.formUnion(ids)
                    }
                } label: {
                    Text(Set(group.items.map(\.id)).isSubset(of: selectedIds) ? "取消" : "全选")
                        .font(.caption.weight(.medium))
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func invoiceRow(_ inv: Invoice) -> some View {
        if isSelecting {
            HStack(spacing: 10) {
                Image(systemName: selectedIds.contains(inv.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
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
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("合计").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "¥%.2f", totalAmount))
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("待提交").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "¥%.2f", pendingAmount))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Text("\(filtered.count) 张")
                if let key = filterMonthKey,
                   let title = allMonthOptions.first(where: { $0.key == key })?.title {
                    Text("· \(title)")
                } else {
                    Text("· 全部月份")
                }
                if batches.count > 0 {
                    Text("· \(batches.count) 批次")
                }
            }
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
                Button {
                    if isAllSelected {
                        selectedIds.subtract(allFilteredIds)
                    } else {
                        selectedIds.formUnion(allFilteredIds)
                    }
                } label: {
                    Text(isAllSelected ? "取消全选" : "全选")
                }
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
