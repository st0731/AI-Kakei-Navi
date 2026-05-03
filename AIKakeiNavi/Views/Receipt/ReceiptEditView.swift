import SwiftUI
import SwiftData

struct ReceiptEditView: View {
    @Bindable var receipt: SavedReceipt
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputActive: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("収支種別", selection: $receipt.isIncome) {
                        Text("支出").tag(false)
                        Text("収入").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent {
                        HStack {
                            TextField("0", value: $receipt.total, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($isInputActive)
                            Text("円")
                        }
                    } label: {
                        Text(receipt.isIncome ? "金額" : "合計金額")
                    }

                    DatePicker("日付", selection: $receipt.receiptDate, displayedComponents: [.date])
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .onChange(of: receipt.receiptDate) { _, newDate in
                            if !receipt.isIncome {
                                receipt.weekday = weekdayString(from: newDate)
                            }
                        }

                    if !receipt.isIncome {
                        menuPicker("必要度", selection: $receipt.necessity,
                                   options: ReceiptAnalysisView.necessityOptions)
                        menuPicker("カテゴリ", selection: $receipt.category,
                                   options: ReceiptAnalysisView.categoryOptions)
                        menuPicker("支払い方法", selection: $receipt.paymentMethod,
                                   options: ReceiptAnalysisView.paymentMethods)
                    }

                    LabeledContent("メモ") {
                        TextField("メモを入力", text: $receipt.memo)
                            .multilineTextAlignment(.trailing)
                            .focused($isInputActive)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("記録を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func menuPicker(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.blue)
        }
    }

    private func weekdayString(from date: Date) -> String {
        let weekdays = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]
        let index = Calendar.current.component(.weekday, from: date) - 1
        return weekdays[index]
    }
}
