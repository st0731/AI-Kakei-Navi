import SwiftUI
import SwiftData

struct ReceiptHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedReceipt.receiptDate, order: .reverse) private var receipts: [SavedReceipt]
    @State private var editingReceipt: SavedReceipt?

    var body: some View {
        NavigationStack {
            List {
                ForEach(receipts) { receipt in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(receipt.isIncome ? (receipt.memo.isEmpty ? "収入" : receipt.memo) : receipt.category)
                                .font(.headline)
                                .lineLimit(1)

                            Text("\(formatDate(receipt.receiptDate))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 6) {
                            Text("\(receipt.isIncome ? "+" : "")\(receipt.total.formatted())円")
                                .font(.system(.body, design: .rounded))
                                .bold()
                                .foregroundColor(receipt.isIncome ? .green : .primary)

                            if !receipt.isIncome {
                                HStack(spacing: 4) {
                                    Text(receipt.category)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue).cornerRadius(4)

                                    Text(receipt.necessity)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.necessity(receipt.necessity).opacity(0.1))
                                        .foregroundColor(Color.necessity(receipt.necessity)).cornerRadius(4)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("カテゴリ: \(receipt.category)、必要度: \(receipt.necessity)")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { editingReceipt = receipt }
                }
                .onDelete(perform: deleteReceipts)
            }
            .navigationTitle("保存済み履歴")
            .sheet(item: $editingReceipt) { receipt in
                ReceiptEditView(receipt: receipt)
            }
            .overlay {
                if receipts.isEmpty {
                    ContentUnavailableView("履歴がありません", systemImage: "tray", description: Text("記録を追加するとここに表示されます"))
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d(EEE)"
        return formatter.string(from: date)
    }

    func deleteReceipts(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(receipts[index])
        }
    }
}
