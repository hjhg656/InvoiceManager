import SwiftUI

struct InvoiceDetailView: View {
    @Bindable var invoice: Invoice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.10, green: 0.11, blue: 0.16)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // 预览区
                        if let data = invoice.imageData, let ui = UIImage(data: data) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                                }
                                .padding(.horizontal)
                        } else if invoice.imageData != nil {
                            // PDF 等
                            VStack(spacing: 12) {
                                Image(systemName: "doc.richtext.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("PDF 文件已保存")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .background {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            }
                            .padding(.horizontal)
                        }

                        // 金额大字
                        VStack(spacing: 4) {
                            Text("金额")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "¥%.2f", invoice.amount))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .padding(.horizontal)

                        // 信息卡片
                        VStack(spacing: 0) {
                            detailRow("商家", invoice.vendor.isEmpty ? "—" : invoice.vendor)
                            Divider().padding(.leading, 16)
                            detailRow("分类", invoice.category)
                            Divider().padding(.leading, 16)
                            detailRow("日期", invoice.date.formatted(date: .long, time: .omitted))
                            Divider().padding(.leading, 16)
                            detailRow("来源", sourceLabel)
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .padding(.horizontal)

                        if !invoice.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("备注")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(invoice.notes)
                                    .font(.body)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            }
                            .padding(.horizontal)
                        }

                        Button(role: .destructive) {
                            modelContext.delete(invoice)
                            dismiss()
                        } label: {
                            Text("删除发票")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sourceLabel: String {
        switch invoice.source {
        case "photo": return "拍照 / 相册"
        case "file": return "文件导入"
        case "email": return "邮件"
        default: return "手动录入"
        }
    }
}
