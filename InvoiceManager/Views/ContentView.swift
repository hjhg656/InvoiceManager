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

    private var grandTotal: Double {
        filtered.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.14, blue: 0.22),
                        Color(red: 0.08, green: 0.09, blue: 0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if invoices.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            summaryCard
                            ForEach(grouped, id: \.key) { group in
                                monthSection(group)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 100)
                    }
                }
            }
            .navigationTitle("发票")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .searchable(text: $searchText, prompt: "搜索商家、分类、备注")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
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
        .preferredColorScheme(.dark)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前筛选合计")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(String(format: "¥%.2f", grandTotal))
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("\(filtered.count) 张发票")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .padding(.top, 8)
    }

    private func monthSection(_ group: (key: String, title: String, items: [Invoice], total: Double)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.title).font(.headline)
                Spacer()
                Text(String(format: "¥%.2f", group.total))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, inv in
                    InvoiceRow(invoice: inv)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedInvoice = inv }
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation {
                                    modelContext.delete(inv)
                                    try? modelContext.save()
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }

                    if index < group.items.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("还没有发票")
                .font(.title2.weight(.semibold))
            Text("点右上角 + ，支持手动填写、拍照、相册，或从文件一次导入多张电子发票 PDF")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button { showAdd = true } label: {
                Label("添加发票", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.top, 8)
        }
    }
}

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.vendor.isEmpty ? "未填商家" : invoice.vendor)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(invoice.category)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                    Text(invoice.date, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(String(format: "¥%.2f", invoice.amount))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = invoice.imageData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: invoice.source == "file" ? "doc.richtext" : "doc.text")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Invoice.self, inMemory: true)
}
