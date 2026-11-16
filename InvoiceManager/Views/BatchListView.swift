import SwiftUI
import SwiftData

struct BatchListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExpenseBatch.createdAt, order: .reverse) private var batches: [ExpenseBatch]
    @State private var sharePayload: SharePayload?

    var body: some View {
        NavigationStack {
            List {
                if batches.isEmpty {
                    ContentUnavailableView("暂无批次", systemImage: "folder", description: Text("在列表里多选发票后，可打成报销批次"))
                } else {
                    ForEach(batches, id: \.id) { batch in
                        NavigationLink {
                            BatchDetailView(batch: batch)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(batch.name).font(.headline)
                                HStack {
                                    Text("\(batch.count) 张")
                                    Text("·")
                                    Text(String(format: "¥%.2f", batch.totalAmount))
                                    Spacer()
                                    Text(batch.createdAt, format: .dateTime.month().day())
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                // 只删批次，发票保留
                                let invs = batch.invoices ?? []
                                for inv in invs { inv.batch = nil }
                                modelContext.delete(batch)
                                try? modelContext.save()
                            } label: {
                                Label("删除批次", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("报销批次")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $sharePayload) { ActivityView(activityItems: $0.urls) }
        }
    }
}

struct BatchDetailView: View {
    @Bindable var batch: ExpenseBatch
    @Environment(\.modelContext) private var modelContext
    @State private var sharePayload: SharePayload?

    private var invoices: [Invoice] {
        (batch.invoices ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("合计") {
                    Text(String(format: "¥%.2f", batch.totalAmount))
                        .fontWeight(.bold)
                }
                LabeledContent("张数", value: "\(batch.count)")
                LabeledContent("创建") {
                    Text(batch.createdAt, format: .dateTime.year().month().day())
                }
            }

            Section("操作") {
                Button {
                    for inv in invoices { inv.statusRaw = InvoiceStatus.reimbursed.rawValue }
                    try? modelContext.save()
                } label: {
                    Label("全部标为已报销", systemImage: "checkmark.seal")
                }
                Button {
                    if let csv = ExportService.makeCSV(invoices: invoices) {
                        var urls = [csv]
                        urls.append(contentsOf: ExportService.attachmentFileURLs(invoices: invoices))
                        sharePayload = SharePayload(urls: urls, title: batch.name)
                    }
                } label: {
                    Label("导出本批次给财务", systemImage: "square.and.arrow.up")
                }
            }

            Section("发票") {
                ForEach(invoices, id: \.id) { inv in
                    NavigationLink {
                        InvoiceDetailView(invoice: inv)
                    } label: {
                        InvoiceRow(invoice: inv)
                    }
                }
            }
        }
        .navigationTitle(batch.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharePayload) { ActivityView(activityItems: $0.urls) }
    }
}
