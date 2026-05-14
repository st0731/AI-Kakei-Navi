import SwiftUI
import SwiftData

struct AdviceView: View {
    @Query private var allReceipts: [SavedReceipt]
    @State private var adviceService = AdviceLLMService()
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    private let suggestions = [
        "節約のアドバイスをして",
        "一番無駄な出費はどこ？",
        "支出の全体的な傾向を教えて",
    ]

    @ObservedObject var aiManager = AIServiceManager.shared
    @State private var showDownloadSheet = false
    @AppStorage("adviceAnalysisPeriod") private var advicePeriodRaw: String = AdviceAnalysisPeriod.threeMonths.rawValue

    var body: some View {
        NavigationStack {
            Group {
                if aiManager.hasDownloadedModel {
                    qaInterface
                } else {
                    lockedStateView
                }
            }
            .navigationTitle("節約AI")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if aiManager.hasDownloadedModel && !adviceService.currentQuestion.isEmpty {
                        Button {
                            adviceService.clearAnswer()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .sheet(isPresented: $showDownloadSheet) {
                ModelDownloadView()
            }
        }
    }

    private var qaInterface: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if !adviceService.dataWarningMessage.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(adviceService.dataWarningMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    if adviceService.currentQuestion.isEmpty && !adviceService.isRunning {
                        emptyStateView
                            .padding(.top, 16)
                    } else {
                        questionAndAnswerView
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.never)
            .onTapGesture {
                isInputFocused = false
            }

            Divider()
            inputBar
        }
    }

    private var questionAndAnswerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 質問カード
            HStack {
                Spacer(minLength: 40)
                Text(adviceService.currentQuestion)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(18)
                    .cornerRadius(4, corners: [.bottomRight])
            }

            // 回答カード
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: adviceService.isAnswerBlocked ? "exclamationmark.shield.fill" : "bubble.left.and.bubble.right.fill")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(6)
                    .background(adviceService.isAnswerBlocked ? Color.orange : Color.blue)
                    .clipShape(Circle())

                Group {
                    if adviceService.isRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            if !adviceService.statusText.isEmpty {
                                Text(adviceService.statusText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            TypingIndicator()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .cornerRadius(18)
                                .cornerRadius(4, corners: [.bottomLeft])
                        }
                    } else if !adviceService.currentAnswer.isEmpty {
                        Text(adviceService.currentAnswer)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                adviceService.isAnswerBlocked
                                    ? Color.orange.opacity(0.10)
                                    : Color(UIColor.secondarySystemGroupedBackground)
                            )
                            .cornerRadius(18)
                            .cornerRadius(4, corners: [.bottomLeft])
                            .overlay(
                                Group {
                                    if adviceService.isAnswerBlocked {
                                        RoundedRectangle(cornerRadius: 18)
                                            .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                    }
                                }
                            )
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = adviceService.currentAnswer
                                } label: {
                                    Label("コピー", systemImage: "doc.on.doc")
                                }
                            }
                    }
                }

                Spacer(minLength: 40)
            }
        }
    }

    private var lockedStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue.opacity(0.6))

            Text("AI機能がロックされています")
                .font(.headline)

            Text("節約AI機能を利用するには\nモデルのダウンロードが必要です")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { showDownloadSheet = true }) {
                Text("モデルをダウンロードする")
                    .fontWeight(.bold)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top, 10)
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue.opacity(0.7))

            Text("支出データをもとにAIが\nアドバイスします")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        sendMessage(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 20)

            Text("AIによる参考情報です。専門家の財務アドバイスの代替ではありません。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("質問を入力...", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(20)
                    .focused($isInputFocused)
                    .disabled(adviceService.isRunning)

                Button {
                    let text = inputText
                    inputText = ""
                    isInputFocused = false
                    sendMessage(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(canSend ? .blue : .gray.opacity(0.4))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            VStack(spacing: 3) {
                Text("AIによる参考情報です。専門家の財務アドバイスの代替ではありません。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text("分析期間: \(advicePeriodRaw) · 設定タブから変更できます")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty && !adviceService.isRunning
    }

    private func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await adviceService.sendMessage(userText: text, receipts: allReceipts)
        }
    }
}

// MARK: - TypingIndicator

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever()
                        .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

// MARK: - Corner Radius Helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
