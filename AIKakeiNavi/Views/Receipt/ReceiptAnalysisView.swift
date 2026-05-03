import SwiftUI
import PhotosUI
import SwiftData
import Vision

struct ReceiptAnalysisView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var isIncome = false

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var llmService = LLMService()
    @State private var processingTask: Task<Void, Never>?
    @FocusState private var isInputActive: Bool

    @State private var showDownloadSheet = false
    @State private var showPhotosPicker = false
    @State private var showCamera = false
    @State private var showInputSourceDialog = false
    @State private var cameraImage: UIImage? = nil
    @State private var isSaving = false
    @State private var showProcessingError = false
    @State private var showSaveError = false

    @State private var editMemo = ""
    @State private var editDate = Date()
    @State private var editWeekday: String = {
        let weekdays = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]
        let index = Calendar.current.component(.weekday, from: Date()) - 1
        return weekdays[index]
    }()
    @State private var editNecessity = "必要"
    @State private var editCategory = "食費"
    @State private var editTotal: Int? = nil
    @State private var editPayment = "現金"
    @State private var selectedImage: UIImage? = nil
    @State private var showFullScreenImage = false

    static let weekdays = ["月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日", "日曜日", "不明"]
    static let necessityOptions = ["必要", "便利", "贅沢"]
    static let categoryOptions = ["食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費", "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費", "サブスク費", "勉強費", "その他"]
    static let paymentMethods = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]

    static let jpLocale = Locale(identifier: "ja_JP")
    static let numberFormat = IntegerFormatStyle<Int>.number

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("収支種別", selection: $isIncome) {
                    Text("支出").tag(false)
                    Text("収入").tag(true)
                }
                .pickerStyle(.segmented)
                .padding()

                Form {
                    Section {
                        if isIncome {
                            LabeledContent {
                                HStack {
                                    TextField("0", value: $editTotal, format: Self.numberFormat)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .focused($isInputActive)
                                    Text("円")
                                }
                            } label: {
                                labelWithTapDismiss("金額")
                            }

                            HStack {
                                Text("日付")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { isInputActive = false }
                                DatePicker("", selection: $editDate, displayedComponents: [.date])
                                    .environment(\.locale, Self.jpLocale)
                                    .labelsHidden()
                            }

                            LabeledContent {
                                TextField("メモ", text: $editMemo)
                                    .multilineTextAlignment(.trailing)
                                    .focused($isInputActive)
                            } label: {
                                labelWithTapDismiss("詳細メモ")
                            }

                        } else {
                            LabeledContent {
                                HStack {
                                    TextField("0", value: $editTotal, format: Self.numberFormat)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .focused($isInputActive)
                                    Text("円")
                                }
                            } label: {
                                labelWithTapDismiss("合計金額")
                            }

                            HStack {
                                Text("日付")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { isInputActive = false }
                                DatePicker("", selection: $editDate, displayedComponents: [.date])
                                    .environment(\.locale, Self.jpLocale)
                                    .labelsHidden()
                            }

                            customMenuPicker(label: "曜日", selection: $editWeekday, options: Self.weekdays)
                            customMenuPicker(label: "必要度", selection: $editNecessity, options: Self.necessityOptions)
                            customMenuPicker(label: "カテゴリ", selection: $editCategory, options: Self.categoryOptions)
                            customMenuPicker(label: "支払い方法", selection: $editPayment, options: Self.paymentMethods)
                        }
                    } header: {
                        HStack {
                            Text(isIncome ? "収入の記録" : "支出の記録")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isInputActive = false }
                    }
                }
                .onTapGesture { isInputActive = false }
                .scrollDismissesKeyboard(.immediately)

                VStack(spacing: 12) {
                    if !isIncome {
                        Button(action: {
                            if AIServiceManager.shared.hasDownloadedModel {
                                showInputSourceDialog = true
                            } else {
                                showDownloadSheet = true
                            }
                        }) {
                            HStack {
                                Image(systemName: AIServiceManager.shared.hasDownloadedModel ? "sparkles" : "lock.fill")
                                Text("画像から自動入力")
                                if !AIServiceManager.shared.hasDownloadedModel {
                                    Text("(要ダウンロード)").font(.caption2)
                                }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.blue.opacity(0.1)).cornerRadius(12)
                        }
                        .photosPicker(isPresented: $showPhotosPicker, selection: $selectedItems, maxSelectionCount: 1, matching: .images)
                    }

                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .cornerRadius(10)
                            .onTapGesture { showFullScreenImage = true }
                            .overlay(alignment: .topTrailing) {
                                Button { selectedImage = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .padding(6)
                                }
                            }
                    }

                    Button {
                        Task { await saveToDatabaseAsync() }
                    } label: {
                        Label("履歴に保存する", systemImage: "tray.and.arrow.down.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 12).bold()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || (editTotal == nil))
                }
                .padding()
                .background(Color(UIColor.systemGroupedBackground))
            }
            .overlay {
                if llmService.isRunning { LoadingOverlay(message: llmService.status) }
                if isSaving { LoadingOverlay(message: "保存中...") }
            }
            .sheet(isPresented: $showDownloadSheet) {
                ModelDownloadView()
            }
            .fullScreenCover(isPresented: $showFullScreenImage) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .onTapGesture { showFullScreenImage = false }
            }
            .alert("画像の解析に失敗しました", isPresented: $showProcessingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("レシートが読み取れませんでした。画像を明るく・水平に撮影してから再度お試しください。")
            }
            .alert("保存に失敗しました", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("データの保存に失敗しました。再度お試しください。")
            }
            .navigationTitle(isIncome ? "収入登録" : "支出登録")
            .onChange(of: selectedItems) { _, newItems in
                isInputActive = false
                guard let newItem = newItems.first else { return }
                processingTask?.cancel()
                processingTask = Task { await processImage(item: newItem) }
            }
            .onChange(of: editDate) { _, newDate in
                editWeekday = weekdayString(from: newDate)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    processingTask?.cancel()
                    processingTask = nil
                }
            }
            .confirmationDialog("画像の選択方法", isPresented: $showInputSourceDialog) {
                Button("カメラで撮影") { showCamera = true }
                Button("フォトライブラリから選択") { showPhotosPicker = true }
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocumentCameraView(image: $cameraImage)
            }
            .onChange(of: cameraImage) { _, newImage in
                guard let img = newImage else { return }
                cameraImage = nil
                processingTask?.cancel()
                processingTask = Task { await processUIImage(img) }
            }
        }
    }

    @ViewBuilder
    private func labelWithTapDismiss(_ text: String) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isInputActive = false }
    }

    @ViewBuilder
    private func customMenuPicker(label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            labelWithTapDismiss(label)
            
            Spacer()

            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.blue)
            .onTapGesture { isInputActive = false }
        }
    }


    func saveToDatabaseAsync() async {
        guard !isSaving else { return }
        isSaving = true
        isInputActive = false

        let newRecord = SavedReceipt(
            isIncome: isIncome,
            memo: isIncome ? editMemo : "",
            receiptDate: editDate,
            weekday: isIncome ? "" : editWeekday,
            necessity: isIncome ? "" : editNecessity,
            category: isIncome ? "" : editCategory,
            total: editTotal ?? 0,
            paymentMethod: isIncome ? "未設定" : editPayment
        )
        modelContext.insert(newRecord)

        do {
            try modelContext.save()
        } catch {
            await MainActor.run {
                isSaving = false
                showSaveError = true
            }
            return
        }

        // 保存完了をユーザーが実感できるよう短時間待機
        try? await Task.sleep(nanoseconds: 500_000_000)

        await MainActor.run {
            isSaving = false
            clearForm()
        }
    }

    func processImage(item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else { return }
        await processUIImage(uiImage)
    }

    func processUIImage(_ uiImage: UIImage) async {
        guard let cgImage = uiImage.cgImage else { return }

        await MainActor.run { selectedImage = uiImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ja-JP"]

        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let observations = request.results ?? []
            let fullText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")

            guard !fullText.isEmpty else {
                await MainActor.run { selectedItems = []; showProcessingError = true }
                return
            }

            await llmService.processWithLLM(ocrText: fullText)

            if let res = llmService.lastReceipt {
                await MainActor.run {
                    let parsedDate = parseFlexibleDate(res.date)
                    editDate = parsedDate
                    editWeekday = weekdayString(from: parsedDate)
                    if Self.necessityOptions.contains(res.necessity) { editNecessity = res.necessity }
                    if Self.categoryOptions.contains(res.category) { editCategory = res.category }
                    if Self.paymentMethods.contains(res.paymentMethod) { editPayment = res.paymentMethod }
                    editTotal = res.total
                    selectedItems = []
                }
            }
        } catch {
            await MainActor.run {
                selectedItems = []
                showProcessingError = true
            }
        }
    }


    private func clearForm() {
        editTotal = nil
        editMemo = ""
        editDate = Date()
        selectedImage = nil
        isInputActive = false
    }

    private func weekdayString(from date: Date) -> String {
        let weekdays = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]
        let index = Calendar.current.component(.weekday, from: date) - 1
        return weekdays[index]
    }

    private func parseFlexibleDate(_ dateString: String) -> Date {
        let formats = ["yyyy/MM/dd", "yyyy/M/d", "yyyy-MM-dd", "yyyy年MM月dd日"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) { return date }
        }
        return Date()
    }
}

// MARK: - DocumentCameraView

struct DocumentCameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView
        init(_ parent: DocumentCameraView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { parent.dismiss(); return }
            parent.image = scan.imageOfPage(at: 0)
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
