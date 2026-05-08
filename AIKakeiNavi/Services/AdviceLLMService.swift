import Foundation
import MLXLLM
import MLXLMCommon
import SwiftData

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

// Stage 1: ユーザーの質問の意図カテゴリ
enum QueryIntent: String {
    case advice   // 節約・削減アドバイス
    case overview // 支出全体の傾向・推移
    case category // 特定カテゴリの詳細
    case payment  // 支払い方法の分析
    case score    // 家計スコア・評価
    case weekday  // 曜日・時期の傾向
    case help     // AIの機能・使い方
    case other    // 上記以外（全データ使用）

    // 意図 → 必要データセクションのマッピング（Swiftが決定論的に担う）
    var sections: [QuerySection] {
        switch self {
        case .advice:   return [.summary, .saving]
        case .overview: return [.summary, .trend, .necessity]
        case .category: return [.category, .necessity, .summary]
        case .payment:  return [.payment, .summary]
        case .score:    return [.summary, .necessity]
        case .weekday:  return [.weekday, .trend, .summary]
        case .help:     return []
        case .other:    return QuerySection.allCases
        }
    }

    static func parse(from text: String) -> QueryIntent {
        let word = text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        // 英単語の完全一致（理想ケース）
        if let intent = QueryIntent(rawValue: word) { return intent }

        // 日本語フォールバック（モデルが日本語を返した場合）
        // 競合を避けるため weekday → score → advice → overview の順でチェック
        if text.contains("曜日") || text.contains("週末") || text.contains("時期") { return .weekday }
        if text.contains("スコア") || text.contains("評価") || text.contains("健全") || text.contains("点数")
            || text.contains("大丈夫") || text.contains("使いすぎ") || text.contains("しすぎ") { return .score }
        if text.contains("節約") || text.contains("アドバイス") || text.contains("削減")
            || text.contains("無駄") || text.contains("貯金") || text.contains("減らす")
            || text.contains("減らせ") || text.contains("改善") { return .advice }
        if text.contains("全体") || text.contains("推移") || text.contains("概要") || text.contains("傾向")
            || text.contains("今月") || text.contains("先月") || text.contains("毎月") { return .overview }
        if text.contains("食費") || text.contains("交通") || text.contains("カテゴリ") || text.contains("詳細")
            || text.contains("外食") || text.contains("サブスク") || text.contains("コンビニ")
            || text.contains("日用品") || text.contains("趣味") || text.contains("娯楽") { return .category }
        if text.contains("支払") || text.contains("現金") || text.contains("カード") || text.contains("決済")
            || text.contains("電子マネー") || text.contains("キャッシュレス") { return .payment }
        if text.contains("機能") || text.contains("使い方") || text.contains("できる")
            || text.contains("できます") || text.contains("答えられ") { return .help }
        return .other
    }
}

// Stage 2: システムプロンプトに含めるデータセクション
enum QuerySection: String, CaseIterable {
    case summary   = "summary"
    case saving    = "saving"
    case payment   = "payment"
    case trend     = "trend"
    case weekday   = "weekday"
    case necessity = "necessity"
    case category  = "category"
}

enum AdviceAnalysisPeriod: String, CaseIterable {
    case oneMonth    = "1ヶ月"
    case threeMonths = "3ヶ月"
    case sixMonths   = "6ヶ月"
    case oneYear     = "1年"
    case all         = "全期間"

    var months: Int? {
        switch self {
        case .oneMonth:    return 1
        case .threeMonths: return 3
        case .sixMonths:   return 6
        case .oneYear:     return 12
        case .all:         return nil
        }
    }
}

@MainActor
@Observable
class AdviceLLMService {
    var messages: [ChatMessage] = []
    var isRunning = false
    var downloadProgress: Double = 0.0
    var statusText = ""
    var streamingResponse: String = ""
    var dataWarningMessage: String = ""

    private let maxHistoryTurns = 5

    // MARK: - AnalysisContext（計算済み中間データ）

    private struct AnalysisContext {
        let periodLabel: String
        let totalAmount: Int
        let recordCount: Int
        let avgMonthlyTotal: Int
        let spendingScore: Int
        let scoreMessage: String
        let savingPotentialMessage: String
        let paymentMethodMessage: String
        let spendingTrendMessage: String
        let weekdayTrendMessage: String
        let necessityLines: String
        let categoryLines: String
        let paymentLines: String
        let weekdayLines: String
    }

    // MARK: - Public API

    func sendMessage(userText: String, receipts: [SavedReceipt]) async {
        guard !userText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        messages.append(ChatMessage(role: "user", content: userText))
        isRunning = true
        downloadProgress = 0.0
        statusText = "準備中..."
        streamingResponse = ""
        dataWarningMessage = ""

        var finalResponse = ""

        #if DEBUG
        let sessionStart = Date()
        print("\n[AdviceLLM] ════════════════════════════════════════════")
        print("[AdviceLLM] ▶ sendMessage 開始: \(Date())")
        print("[AdviceLLM]   入力: \"\(userText)\"")
        print("[AdviceLLM]   レシート総数: \(receipts.count)件（支出: \(receipts.filter { !$0.isIncome }.count)件・収入: \(receipts.filter { $0.isIncome }.count)件）")
        #endif

        do {
            #if DEBUG
            let loadStart = Date()
            print("[AdviceLLM] ⏳ モデルロード開始...")
            #endif

            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: AIServiceManager.shared.localModelURL,
                using: HuggingFaceTokenizerLoader()
            )

            #if DEBUG
            print("[AdviceLLM] ✅ モデルロード完了: \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))秒")
            #endif

            // Stage 1: 意図分類（modelContainerを共用）
            self.statusText = "質問を分析中..."
            self.downloadProgress = 1.0

            #if DEBUG
            print("[AdviceLLM] ─── Stage 1: 意図分類 ───────────────────────")
            let stage1Start = Date()
            #endif

            let intent = try await classifyIntent(userText: userText, modelContainer: modelContainer)
            let sections = intent.sections

            #if DEBUG
            print("[AdviceLLM] ⏱ Stage 1 完了: \(String(format: "%.2f", Date().timeIntervalSince(stage1Start)))秒")
            print("[AdviceLLM]   intent  : \(intent.rawValue)")
            print("[AdviceLLM]   sections: [\(sections.map { $0.rawValue }.joined(separator: ", "))]")
            #endif

            // Stage 2: 絞り込んだシステムプロンプトで回答生成
            let systemPrompt = buildSystemPrompt(receipts: receipts, sections: sections)

            let conversationMessages = buildConversationMessages(system: systemPrompt)

            #if DEBUG
            print("[AdviceLLM] ─── Stage 2: 回答生成 ────────────────────────")
            print("[AdviceLLM]   システムプロンプト: \(systemPrompt.count)文字")
            print("[AdviceLLM]   会話履歴: \(conversationMessages.count)メッセージ（system含む）")
            print("[AdviceLLM] --- システムプロンプト全文 ---")
            print(systemPrompt)
            print("[AdviceLLM] --- システムプロンプト終了 ---")
            let stage2Start = Date()
            #endif

            self.statusText = "回答生成中..."

            let result = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(
                    input: .init(messages: conversationMessages)
                )

                var params = GenerateParameters()
                params.maxTokens = 1200

                var accumulated = ""

                let generateResult: GenerateResult = try MLXLMCommon.generate(
                    input: input,
                    parameters: params,
                    context: context,
                    didGenerate: { tokens in
                        let piece = context.tokenizer.decode(tokenIds: tokens)
                        accumulated += piece

                        let snapshot = accumulated
                        Task { @MainActor in
                            if snapshot.contains("</think>") {
                                let parts = snapshot.components(separatedBy: "</think>")
                                var display = parts.last ?? snapshot
                                let stopTokens = ["<|im_end|>", "<|im_start|>", "</s>"]
                                for token in stopTokens {
                                    if let range = display.range(of: token) {
                                        display = String(display[..<range.lowerBound])
                                    }
                                }
                                self.streamingResponse = display.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else if snapshot.contains("<think>") {
                                self.streamingResponse = "思考中..."
                            } else {
                                var display = snapshot
                                let stopTokens = ["<|im_end|>", "<|im_start|>", "</s>"]
                                for token in stopTokens {
                                    if let range = display.range(of: token) {
                                        display = String(display[..<range.lowerBound])
                                    }
                                }
                                self.streamingResponse = display
                            }
                        }
                        return .more
                    }
                )
                #if DEBUG
                print("[AdviceLLM] ⚡ Stage 2 生成完了: \(String(format: "%.1f", generateResult.tokensPerSecond)) tok/s")
                print("[AdviceLLM]   生テキスト(\(generateResult.output.count)文字): \"\(generateResult.output.prefix(120))...\"")
                #endif
                return generateResult.output
            }

            finalResponse = cleanResponse(result)

            #if DEBUG
            print("[AdviceLLM] ⏱ Stage 2 完了: \(String(format: "%.2f", Date().timeIntervalSince(stage2Start)))秒")
            #endif

        } catch {
            finalResponse = "回答の生成中にエラーが発生しました。もう一度お試しください。"
            #if DEBUG
            print("[AdviceLLM] ❌ エラー発生: \(type(of: error))")
            print("[AdviceLLM]   localizedDescription: \(error.localizedDescription)")
            print("[AdviceLLM]   error: \(error)")
            #endif
        }

        if !finalResponse.contains("エラー") {
            AIServiceManager.shared.completeDownload()
        }

        #if DEBUG
        print("[AdviceLLM] ─── 最終回答 ──────────────────────────────────")
        print(finalResponse)
        print("[AdviceLLM] ─── 回答終了（\(finalResponse.count)文字）──────────────")
        print("[AdviceLLM] ⏱ 合計所要時間: \(String(format: "%.2f", Date().timeIntervalSince(sessionStart)))秒")
        print("[AdviceLLM] ════════════════════════════════════════════\n")
        #endif

        streamingResponse = ""
        messages.append(ChatMessage(role: "assistant", content: finalResponse))
        statusText = ""
        isRunning = false
    }

    func clearMessages() {
        messages = []
        streamingResponse = ""
        dataWarningMessage = ""
    }

    // MARK: - Stage 1: 意図分類

    private func classifyIntent(userText: String, modelContainer: MLXLMCommon.ModelContainer) async throws -> QueryIntent {
        let prompt = """
        /no_think
        Classify the following question. Output ONLY one English word from the list below. No Japanese. No explanation.

        Valid words: advice, overview, category, payment, score, weekday, help, other

        - advice  : 節約・出費削減アドバイスを求める（例: 節約のコツを教えて、無駄遣いはどこ?）
        - overview: 支出全体の傾向・推移を知りたい（例: 今月どれくらい使った?、先月と比べて?）
        - category: 特定カテゴリの詳細を知りたい（例: 食費はどのくらい?、交通費について教えて）
        - payment : 支払い方法について知りたい（例: 現金とカードどちらが多い?）
        - score   : 家計スコア・評価を知りたい（例: 家計は健全?、スコアは何点?）
        - weekday : 曜日・時期の傾向を知りたい（例: 何曜日が多い?、週末に使いすぎ?）
        - help    : このAIの機能・使い方を知りたい（例: 何ができる?）
        - other   : 上記に当てはまらない

        Question: \(userText)
        Answer (one English word only):
        """

        #if DEBUG
        print("[AdviceLLM] 🔍 分類プロンプト送信中（maxTokens=20）...")
        #endif

        let raw = try await modelContainer.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]])
            )
            var params = GenerateParameters()
            params.maxTokens = 20
            let generateResult: GenerateResult = try MLXLMCommon.generate(
                input: input, parameters: params, context: context,
                didGenerate: { _ in .more }
            )
            #if DEBUG
            print("[AdviceLLM]   Stage 1 生テキスト: \"\(generateResult.output)\"")
            #endif
            return generateResult.output
        }

        let cleaned = cleanResponse(raw)
        let firstWord = cleaned
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let intent = QueryIntent.parse(from: cleaned)

        #if DEBUG
        print("[AdviceLLM]   クリーニング後: \"\(cleaned)\"")
        print("[AdviceLLM]   パース対象語: \"\(firstWord)\"")
        print("[AdviceLLM]   解釈結果: \(firstWord == intent.rawValue ? "✅ 既知カテゴリ" : "⚠️ 未知語 → .other にフォールバック")")
        #endif

        return intent
    }

    // MARK: - Stage 2: システムプロンプト構築

    private func buildSystemPrompt(receipts: [SavedReceipt], sections: [QuerySection]) -> String {
        #if DEBUG
        print("[AdviceLLM] 📝 buildSystemPrompt: sections=[\(sections.map { $0.rawValue }.joined(separator: ", "))]")
        #endif

        // help: データ不要、固定文言
        if sections.isEmpty {
            #if DEBUG
            print("[AdviceLLM]   → help固定文言を使用")
            #endif
            return """
            # 命令文：
            ユーザーはこのAIの機能・使い方について質問しています。

            # このAIについて：
            「節約AI」はユーザーが登録したレシートデータをもとに、以下のことができます：
            ・節約・出費削減のアドバイス（例:「節約のコツを教えて」「無駄遣いはどこ？」）
            ・全体的な支出傾向・推移の分析（例:「今月どれくらい使った？」）
            ・特定カテゴリの詳細（例:「食費はどのくらい？」）
            ・支払い方法の分析（例:「現金とカードどちらが多い？」）
            ・家計スコア・評価（例:「家計は健全？」）
            ・曜日・時期の傾向（例:「何曜日に多く使っている？」）

            以上の機能をユーザーに丁寧に説明してください。

            # 回答の基本原則（最優先）：
            1. **簡潔な回答**: 回答は300字以内で簡潔に。
            2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
            """
        }

        guard let ctx = buildAnalysisContext(receipts: receipts) else {
            dataWarningMessage = "支出データがまだ記録されていません。レシートを登録するとアドバイスの精度が上がります。"
            #if DEBUG
            print("[AdviceLLM]   → データ0件: 固定文言を返す")
            #endif
            return """
            # 命令文：
            ユーザーはまだ支出データを一件も登録していません。支出レポートは存在しません。
            支出データが登録されていないため、支出に基づいたアドバイスや分析はできないことをユーザーに伝えてください。
            レシートを登録するよう、丁寧に促してください。

            # 回答の基本原則（最優先）：
            1. **簡潔な回答**: 回答は200字以内で簡潔に。
            2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
            """
        }

        if ctx.recordCount < 5 {
            dataWarningMessage = "データがまだ\(ctx.recordCount)件のみです。より多くのレシートを登録すると精度の高いアドバイスができます。"
        }

        var parts: [String] = [
            """
            # 命令文：
            以下のユーザーの支出レポートから情報を抜き出すことで、ユーザーの質問に回答してください。

            # 支出レポート（\(ctx.periodLabel)・合計\(ctx.totalAmount)円・\(ctx.recordCount)件）：
            """
        ]

        for section in sections {
            switch section {
            case .summary:   parts.append(sectionSummary(ctx))
            case .saving:    parts.append(sectionSaving(ctx))
            case .payment:   parts.append(sectionPayment(ctx))
            case .trend:     parts.append(sectionTrend(ctx))
            case .weekday:   parts.append(sectionWeekday(ctx))
            case .necessity: parts.append(sectionNecessity(ctx))
            case .category:  parts.append(sectionCategory(ctx))
            }
        }

        parts.append("""
        # 回答の基本原則（最優先）：
        1. **数値の透明性**: 金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
        2. **簡潔な回答**: 回答は300字以内で簡潔に。
        3. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
        4. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。
        """)

        let prompt = parts.joined(separator: "\n\n")
        #if DEBUG
        print("[AdviceLLM]   → セクション\(sections.count)件を組み立て / 合計\(prompt.count)文字")
        #endif
        return prompt
    }

    // MARK: - AnalysisContext Builder

    private func buildAnalysisContext(receipts: [SavedReceipt]) -> AnalysisContext? {
        let expenses = receipts.filter { !$0.isIncome }

        let storedRaw = UserDefaults.standard.string(forKey: "adviceAnalysisPeriod") ?? AdviceAnalysisPeriod.threeMonths.rawValue
        let period = AdviceAnalysisPeriod(rawValue: storedRaw) ?? .threeMonths
        let target: [SavedReceipt]
        let periodLabel: String
        if let months = period.months {
            let since = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
            let filtered = expenses.filter { $0.receiptDate >= since }
            target = filtered.isEmpty ? expenses : filtered
            periodLabel = filtered.isEmpty ? "全期間" : "直近\(period.rawValue)"
        } else {
            target = expenses
            periodLabel = "全期間"
        }

        let recordCount = target.count
        guard recordCount > 0 else { return nil }

        let totalAmount = target.reduce(0) { $0 + $1.total }
        let necessityGroups = Dictionary(grouping: target) { $0.necessity }
        let paymentGroups = Dictionary(grouping: target) { $0.paymentMethod }

        let cashTotal = paymentGroups["現金"]?.reduce(0) { $0 + $1.total } ?? 0
        let cashPct = totalAmount > 0 ? Int(Double(cashTotal) / Double(totalAmount) * 100) : 0

        let targetRatio = UserDefaults.standard.object(forKey: "necessityTargetRatio") as? Double ?? 62.5
        let scalingFactor = 100.0 / targetRatio
        let necessityTotal = necessityGroups["必要"]?.reduce(0) { $0 + $1.total } ?? 0
        let necessityRatio = totalAmount > 0 ? (Double(necessityTotal) / Double(totalAmount) * 100) : 0
        let spendingScore = totalAmount > 0 ? Int(max(0, 100 - (abs(necessityRatio - targetRatio) * scalingFactor))) : 0

        let scoreMessage: String
        if spendingScore >= 90 {
            scoreMessage = "節約疲れもなく、浪費の罪悪感もない。お金が最適に使われた完璧に近い状態です。"
        } else if spendingScore >= 70 {
            scoreMessage = "合格点です。この範囲を維持できていれば、お金のストレスは最小限です。"
        } else if spendingScore >= 40 {
            if necessityRatio > targetRatio {
                scoreMessage = "必要支出の割合が高めです。固定費などの必要な支出を見直すか、少しの贅沢を取り入れて、生活に心のゆとりを持たせることも検討してみてください。"
            } else {
                scoreMessage = "必要支出の割合が低く、便利や贅沢への支出が目立ちます。自炊を取り入れたり、贅沢を少し控えることで、より健全な家計に近づけることができます。"
            }
        } else {
            scoreMessage = "支出のコントロール権を「自分の欲望（便利・贅沢）」に奪われつつあります。家計防衛の観点から赤信号です。"
        }

        let convenienceTotal = necessityGroups["便利"]?.reduce(0) { $0 + $1.total } ?? 0
        let luxuryTotal = necessityGroups["贅沢"]?.reduce(0) { $0 + $1.total } ?? 0
        let convRatio = totalAmount > 0 ? (Double(convenienceTotal) / Double(totalAmount) * 100) : 0
        let luxRatio = totalAmount > 0 ? (Double(luxuryTotal) / Double(totalAmount) * 100) : 0

        var savingPotentials: [String] = []

        if convRatio > 30, let convItems = necessityGroups["便利"] {
            let catTotals = Dictionary(grouping: convItems) { $0.category }
                .mapValues { $0.reduce(0) { $0 + $1.total } }
            let sortedCats = catTotals.sorted { $0.value > $1.value }.prefix(2)
            let catsWithPct = sortedCats.map { entry -> String in
                let pct = convenienceTotal > 0 ? Int(Double(entry.value) / Double(convenienceTotal) * 100) : 0
                return "\(entry.key)(\(pct)%)"
            }
            let catsStr = catsWithPct.joined(separator: "、")
            let tipsStr = sortedCats.compactMap { getConvenienceTip(for: $0.key) }.joined(separator: "")
            savingPotentials.append("便利支出であり、\(convenienceTotal)円（総支出の\(Int(convRatio))%）を占めています。便利支出は主に\(catsStr)で構成されており、ここに大きな節約余地があります。\(tipsStr)")
        }

        if luxRatio > 30, let luxItems = necessityGroups["贅沢"] {
            let catTotals = Dictionary(grouping: luxItems) { $0.category }
                .mapValues { $0.reduce(0) { $0 + $1.total } }
            let sortedCats = catTotals.sorted { $0.value > $1.value }.prefix(2)
            let catsWithPct = sortedCats.map { entry -> String in
                let pct = luxuryTotal > 0 ? Int(Double(entry.value) / Double(luxuryTotal) * 100) : 0
                return "\(entry.key)(\(pct)%)"
            }
            let catsStr = catsWithPct.joined(separator: "、")
            let tipsStr = sortedCats.compactMap { getLuxuryTip(for: $0.key) }.joined(separator: "")
            savingPotentials.append("贅沢支出であり、\(luxuryTotal)円（総支出の\(Int(luxRatio))%）を占めています。贅沢支出は主に\(catsStr)で構成されており、ここに大きな節約余地があります。\(tipsStr)")
        }

        let savingPotentialMessage = savingPotentials.isEmpty
            ? "特にありません。大きな節約余地がないことをユーザーに明示してください。"
            : savingPotentials.joined(separator: "\n")

        let calendar = Calendar.current
        let monthlyGroups = Dictionary(grouping: target) { receipt -> String in
            let comps = calendar.dateComponents([.year, .month], from: receipt.receiptDate)
            return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
        }
        let sortedMonths = monthlyGroups.keys.sorted()
        let monthlyTotals = sortedMonths.map { key -> Int in
            monthlyGroups[key]?.reduce(0) { $0 + $1.total } ?? 0
        }
        let avgMonthlyTotal = monthlyTotals.isEmpty ? 0 : monthlyTotals.reduce(0, +) / monthlyTotals.count

        let spendingTrendMessage: String
        if monthlyTotals.count < 2 {
            spendingTrendMessage = "まだデータが1ヶ月分のみのため、今後の推移に注目していきましょう。"
        } else {
            let latest = monthlyTotals.last ?? 0
            let previous = monthlyTotals[monthlyTotals.count - 2]
            if latest < previous && latest < avgMonthlyTotal {
                spendingTrendMessage = "直近は前月比・平均比ともに減少しており、良いペースで支出をコントロールできています。"
            } else if latest > previous && latest > avgMonthlyTotal {
                spendingTrendMessage = "直近は前月比・平均比ともに増加傾向にあり、支出が膨らみやすい時期かもしれません。引き締めを意識しましょう。"
            } else if latest > previous {
                spendingTrendMessage = "平均よりは抑えられていますが、前月よりは増加しています。微増傾向にあるため注意してください。"
            } else {
                spendingTrendMessage = "前月よりは減少していますが、平均よりは高い水準です。引き続き、平均ラインを目指して調整していきましょう。"
            }
        }

        let paymentMethodMessage = cashPct >= 30
            ? "現金支払いが\(cashTotal)円（総支出の\(cashPct)%）を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
            : "キャッシュレス決済を主体に、ポイント還元などを活用して上手に買い物ができています。"

        let necessityLines = ["必要", "便利", "贅沢"].map { nec -> String in
            let amount = necessityGroups[nec]?.reduce(0) { $0 + $1.total } ?? 0
            let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
            return "   - \(nec)：\(amount)円（総支出の\(pct)%）"
        }.joined(separator: "\n")

        let allCategories = ["食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費", "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費", "サブスク費", "勉強費", "その他"]
        let categoryGroupsAll = Dictionary(grouping: target) { $0.category }
        let categoryLines = allCategories.map { cat -> String in
            let items = categoryGroupsAll[cat] ?? []
            let catTotal = items.reduce(0) { $0 + $1.total }
            let catPct = totalAmount > 0 ? Int(Double(catTotal) / Double(totalAmount) * 100) : 0
            let necInCat = Dictionary(grouping: items) { $0.necessity }
            let necDetails = ["必要", "便利", "贅沢"].map { nec -> String in
                let v = necInCat[nec]?.reduce(0) { $0 + $1.total } ?? 0
                if v > 0 {
                    let localPct = catTotal > 0 ? Int(Double(v) / Double(catTotal) * 100) : 0
                    return "\(cat)の\(nec)支出は\(v)円で\(cat)の\(localPct)%"
                } else {
                    return "\(cat)の\(nec)支出はありません"
                }
            }.joined(separator: "、")
            if catTotal > 0 {
                return "   - \(cat)：\(catTotal)円（総支出の\(catPct)%, \(necDetails)）"
            } else {
                return "   - \(cat)：支出なし（0円, \(necDetails)）"
            }
        }.joined(separator: "\n")

        let allPayments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
        let paymentLines = allPayments.map { method -> String in
            let amount = paymentGroups[method]?.reduce(0) { $0 + $1.total } ?? 0
            let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
            return "   - \(method)：\(amount > 0 ? "\(amount)円" : "支出なし")（総支出の\(pct)%）"
        }.joined(separator: "\n")

        let weekdayGroups = Dictionary(grouping: target) { receipt -> Int in
            calendar.component(.weekday, from: receipt.receiptDate)
        }
        let weekdayNames = ["", "日", "月", "火", "水", "木", "金", "土"]
        var biasedWeekdays: [String] = []
        let weekdayLines = (1...7).map { wd -> String in
            let amount = weekdayGroups[wd]?.reduce(0) { $0 + $1.total } ?? 0
            let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
            if pct >= 30 { biasedWeekdays.append("\(weekdayNames[wd])曜日(\(pct)%)") }
            return "   - \(weekdayNames[wd])曜日：\(amount)円（総支出の\(pct)%）"
        }.joined(separator: "\n")

        let weekdayTrendMessage = biasedWeekdays.isEmpty
            ? "曜日による支出の偏りは特にありません。"
            : "\(biasedWeekdays.joined(separator: "、"))に支出が集中しています。"

        let context = AnalysisContext(
            periodLabel: periodLabel,
            totalAmount: totalAmount,
            recordCount: recordCount,
            avgMonthlyTotal: avgMonthlyTotal,
            spendingScore: spendingScore,
            scoreMessage: scoreMessage,
            savingPotentialMessage: savingPotentialMessage,
            paymentMethodMessage: paymentMethodMessage,
            spendingTrendMessage: spendingTrendMessage,
            weekdayTrendMessage: weekdayTrendMessage,
            necessityLines: necessityLines,
            categoryLines: categoryLines,
            paymentLines: paymentLines,
            weekdayLines: weekdayLines
        )

        #if DEBUG
        print("[AdviceLLM] 📊 AnalysisContext 構築完了:")
        print("[AdviceLLM]   期間: \(periodLabel) / \(recordCount)件 / 合計\(totalAmount)円 / 月平均\(avgMonthlyTotal)円")
        print("[AdviceLLM]   スコア: \(spendingScore)点 → \(scoreMessage.prefix(30))...")
        let hasConvSaving = savingPotentialMessage != "特にありません。大きな節約余地がないことをユーザーに明示してください。"
        print("[AdviceLLM]   節約余地: \(hasConvSaving ? "あり" : "なし（特になし）")")
        print("[AdviceLLM]   支出推移: \(spendingTrendMessage.prefix(40))...")
        print("[AdviceLLM]   曜日傾向: \(weekdayTrendMessage)")
        print("[AdviceLLM]   支払い: \(paymentMethodMessage.prefix(40))...")
        #endif

        return context
    }

    // MARK: - Section Builders

    private func sectionSummary(_ ctx: AnalysisContext) -> String {
        """
        ## 支出サマリー（\(ctx.periodLabel)）
        以下の内容をユーザーに伝えてください：
        ・合計支出：\(ctx.totalAmount)円（\(ctx.recordCount)件）
        ・支出健全度スコア：\(ctx.spendingScore)点
        ・\(ctx.scoreMessage)
        """
    }

    private func sectionSaving(_ ctx: AnalysisContext) -> String {
        """
        ## 節約余地アドバイス
        以下の節約アドバイスをユーザーにそのままお伝えください：
        \(ctx.savingPotentialMessage)
        """
    }

    private func sectionPayment(_ ctx: AnalysisContext) -> String {
        """
        ## 支払い方法の分析
        \(ctx.paymentMethodMessage)

        【支払い方法別内訳】
        \(ctx.paymentLines)
        """
    }

    private func sectionTrend(_ ctx: AnalysisContext) -> String {
        """
        ## 支出の推移
        \(ctx.spendingTrendMessage)
        月平均支出：\(ctx.avgMonthlyTotal)円
        """
    }

    private func sectionWeekday(_ ctx: AnalysisContext) -> String {
        """
        ## 曜日別支出
        \(ctx.weekdayTrendMessage)

        【曜日別内訳】
        \(ctx.weekdayLines)
        """
    }

    private func sectionNecessity(_ ctx: AnalysisContext) -> String {
        """
        ## 必要度別支出
        【必要度別内訳】
        \(ctx.necessityLines)
        """
    }

    private func sectionCategory(_ ctx: AnalysisContext) -> String {
        """
        ## カテゴリ別支出
        【カテゴリ別内訳】
        \(ctx.categoryLines)
        """
    }

    // MARK: - Tips

    private func getConvenienceTip(for category: String) -> String? {
        let tips = [
            "食費": "具体的には、食費ではコンビニや自動販売機などの割高なチャネルを避け、安価なスーパーでのまとめ買いやマイボトルの持参を習慣化してください。",
            "服・美容費": "具体的には、服・美容費では「間に合わせ」の購入を控え、着回しやすい定番アイテムを計画的に買い足すことで、長期的な無駄を減らせます。",
            "日用品・雑貨費": "具体的には、日用品・雑貨費ではストック切れによる場当たり的な購入を避け、安売り時のまとめ買いや大容量パックの活用を意識してください。",
            "交通・移動費": "具体的には、交通・移動費ではタクシーや急ぎの移動を最小限にし、時間に余裕を持って公共交通機関や徒歩を活用することを推奨します。",
            "通信費": "具体的には、通信費では不要なオプションサービスの解約や格安プランへの変更など、一度の手間で済む固定費の削減を優先してください。",
            "水道光熱費": "具体的には、水道光熱費では、つけっぱなしを防ぐ工夫や省エネ家電の活用など、日々の無駄を省く習慣をつけてください。",
            "住居費": "具体的には、住居費では利便性のみを優先した高額な条件を見直し、生活圏の最適化や固定費の低い物件への転居を中長期的に検討してください。",
            "医療・健康費": "具体的には、医療・健康費では市販薬への場当たり的な依存を減らし、ジェネリック医薬品の活用や規則正しい生活による予防を徹底してください。",
            "趣味・娯楽費": "具体的には、趣味・娯楽費では「なんとなく」の課金や遊びを整理し、本当に楽しみたいものに予算を集中させる工夫をしてください。",
            "交際費": "具体的には、交際費では「付き合い」だけでの参加を見直し、本当に大切な人との時間に予算を使うよう意識してください。",
            "サブスク費": "具体的には、サブスク費では「とりあえず登録」を避け、1ヶ月以上使っていないサービスは一旦解約するルールを作ってください。",
            "勉強費": "具体的には、勉強費では話題の本の衝動買いを控え、図書館の予約機能や中古市場を活用してコストを抑えつつ知識を得る方法を検討してください。",
            "その他": "具体的には、使途不明金（小規模な便利支出）を可視化するため、少額決済こそ記録を意識し、財布の紐が緩む「ついでの瞬間」を特定してください。"
        ]
        return tips[category] ?? "日々の「なんとなく」の支出を意識的に減らす工夫をしてみましょう。"
    }

    private func getLuxuryTip(for category: String) -> String? {
        let tips = [
            "食費": "具体的には、食費では外食や高級食材の頻度を抑え、特別な日以外は予算内での自炊を心がけることが大切です。",
            "服・美容費": "具体的には、服・美容費ではブランド品や新作の衝動買いを控え、長く愛用できる上質なものを厳選して購入してください。",
            "日用品・雑貨費": "具体的には、日用品・雑貨費では高級ブランドや消耗品の過剰なアップグレードを避け、実益重視の製品選びを検討してください。",
            "交通・移動費": "具体的には、交通・移動費ではタクシーなどの贅沢な移動手段を特別な場合に限定し、日常は公共機関を優先してください。",
            "通信費": "具体的には、通信費では過剰なデータプランや最新機種への頻繁な買い替えを控え、実際の使用量に合ったプランへの見直しを検討してください。",
            "水道光熱費": "具体的には、水道光熱費では、快適さのための過剰な冷暖房の使用を控え、適正温度での運用を心がけてください。",
            "住居費": "具体的には、住居費ではステータスのための高額な家賃や設備投資を見直し、身の丈に合った住環境への最適化を検討してください。",
            "医療・健康費": "具体的には、医療・健康費では高額なサプリメントや過剰な美容診療を見直し、基本的な生活習慣による予防に注力してください。",
            "趣味・娯楽費": "具体的には、趣味・娯楽費では一度のレジャーにかけすぎず、年間予算を決めて計画的に楽しむことが推奨されます。",
            "交際費": "具体的には、交際費では見栄を張るための奢りや高級店での集まりを控え、身の丈に合った交際を心がけてください。",
            "サブスク費": "具体的には、サブスク費ではプレミアムプランなど上位プランへの過剰な課金を見直し、通常プランで十分でないか確認してください。",
            "勉強費": "具体的には、勉強費では高額なセミナーやスクールに頼りすぎず、独学や安価な教材を活用した自立的な学習を検討してください。",
            "その他": "具体的には、自分への過度なご褒美を控え、支出が本当に人生の質を高めているか再確認する習慣を持ってください。"
        ]
        return tips[category] ?? "その支出が本当に価格に見合う価値を提供しているか、再確認してみましょう。"
    }

    // MARK: - Conversation Helpers

    private func buildConversationMessages(system: String) -> [[String: any Sendable]] {
        var result: [[String: any Sendable]] = [["role": "system", "content": system]]
        for msg in recentHistory() {
            let content = msg.role == "user" ? "/no_think \(msg.content)" : msg.content
            result.append(["role": msg.role == "user" ? "user" : "assistant", "content": content])
        }
        return result
    }

    private func recentHistory() -> [ChatMessage] {
        let maxMessages = maxHistoryTurns * 2
        if messages.count <= maxMessages { return messages }
        return Array(messages.suffix(maxMessages))
    }

    private func cleanResponse(_ text: String) -> String {
        var cleaned = text
        if cleaned.contains("</think>") {
            let parts = cleaned.components(separatedBy: "</think>")
            cleaned = parts.last ?? cleaned
        } else if let thinkStart = cleaned.range(of: "<think>") {
            cleaned = String(cleaned[..<thinkStart.lowerBound])
        }
        let stopTokens = ["<|im_end|>", "<|im_start|>", "</s>"]
        for token in stopTokens {
            if let range = cleaned.range(of: token) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
