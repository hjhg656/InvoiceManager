import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    @State private var showAdd = false
    @State private var searchText = ""
    @State private var selectedInvoice: Invoice?

    private var filtered: [Invoice] {
        if searchText.isEmpty { return invoices }
        let q = searchText.lowercased()
        return invoices.filter {
            $0.vendor.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q) ||
            $0.category.lowercased().contains(q)
        }
    }

    private var grouped: [(key: String, title: String, items: [Invoice], total: Double)] {
        let dict = Dictionary(grouping: filtered) { $0.monthKey }
        return dict.keys.sorted(by: >).map { key in
            let items = dict[key]!.sorted { $0.date > $1.date }
            let total = items.reduce(0) { $0 + $1.amount }
            let title = items.first?.monthTitle ?? key
            return (key, title, items, total)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    ContentUnavailableView(
                        "还没有发票",
                        systemImage: "doc.text",
                        description: Text("点右上角 + 添加第一张发票")
                    )
                } else {
                    List {
                        ForEach(grouped, id: \.key) { group in
                            Section {
                                ForEach(group.items) { inv in
                                    InvoiceRow(invoice: inv)
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectedInvoice = inv }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                modelContext.delete(inv)
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
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("发票管理")
            .searchable(text: $searchText, prompt: "搜索商家、备注、分类")
            .toolbar {
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
            .sheet(item: $selectedInvoice) { inv in
                InvoiceDetailView(invoice: inv)
            }
        }
    }
}

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: 12) {
            if let data = invoice.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.vendor.isEmpty ? "未填商家" : invoice.vendor)
                    .font(.body)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(invoice.category)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    Text(invoice.date, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(String(format: "¥%.2f", invoice.amount))
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(invoice.amount >= 0 ? Color.primary : Color.red)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Invoice.self, inMemory: true)
}
