import Foundation
import MLXLLM
import MLXLMCommon
import SwiftData

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    var isBlocked: Bool = false
}

private struct ContentFilter {
    static let blockedKeywords: [String] = [
        "仮想通貨",
        "ビットコイン",
        "暗号資産",
        "FX",
        "レバレッジ",
        "信用取引",
        "株式投資",
        "証券口座",
    ]

    static func blockedKeyword(in text: String) -> String? {
        blockedKeywords.first { text.contains($0) }
    }
}

// Stage 1: ユーザーの質問の意図カテゴリ
enum QueryIntent: String {
    case advice    // 節約アドバイス（ボトルネック・改善案）
    case overview  // 支出全体サマリー・スコア・catch-all
    case category  // カテゴリ別支出
    case trend     // 時系列・月別推移
    case necessity // 必要度別支出
    case payment   // 支払い方法の分析
    case weekday   // 曜日別支出傾向
    case help      // アプリの機能・使い方
    case offtopic  // 家計と無関係な質問

    // 意図 → 必要データセクションのマッピング（Swiftが決定論的に担う）
    var sections: [QuerySection] {
        switch self {
        case .advice:    return [.summary, .saving]
        case .overview:  return [.summary]
        case .category:  return [.category]
        case .trend:     return [.trend]
        case .necessity: return [.necessity]
        case .payment:   return [.payment]
        case .weekday:   return [.weekday]
        case .help:      return []
        case .offtopic:  return []
        }
    }

    static func parse(from text: String) -> QueryIntent {
        // JSON形式 {"intent": "xxx"} をパース
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let intentStr = json["intent"],
           let intent = QueryIntent(rawValue: intentStr.lowercased()) {
            return intent
        }
        return .overview
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
    static let allCategories = ["食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費", "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費", "サブスク費", "勉強費", "その他"]

    var messages: [ChatMessage] = []
    var isRunning = false
    var downloadProgress: Double = 0.0
    var statusText = ""
    var streamingResponse: String = ""
    var dataWarningMessage: String = ""

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
        let monthlyLines: String
        let trendByNecessityLines: String
        let trendByCategoryLines: String
        let weekdayByNecessityLines: String
        let weekdayByCategoryLines: String
        let topCategoryLines: String
        let necessityByCategoryLines: String
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
        var isMessageBlocked = false

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

            #if DEBUG
            print("[AdviceLLM] ⏱ Stage 1 完了: \(String(format: "%.2f", Date().timeIntervalSince(stage1Start)))秒")
            print("[AdviceLLM]   intent  : \(intent.rawValue)")
            print("[AdviceLLM]   sections: [\(intent.sections.map { $0.rawValue }.joined(separator: ", "))]")
            #endif

            // Stage 2: 絞り込んだシステムプロンプトで回答生成
            let systemPrompt = buildSystemPrompt(receipts: receipts, intent: intent)

            let conversationMessages = buildConversationMessages(system: systemPrompt, userText: userText)

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

            if let hit = ContentFilter.blockedKeyword(in: finalResponse) {
                finalResponse = "この回答には投資に関する情報が含まれていたため、表示できませんでした。節約や支出管理についての質問をお試しください。"
                isMessageBlocked = true
                #if DEBUG
                print("[AdviceLLM] 🚫 コンテンツフィルター発動: キーワード「\(hit)」を検出")
                #endif
            }

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
        messages.append(ChatMessage(role: "assistant", content: finalResponse, isBlocked: isMessageBlocked))
        statusText = ""
        isRunning = false
    }

    func clearMessages() {
        messages = []
        streamingResponse = ""
        dataWarningMessage = ""
    }

    // MARK: - Stage 1: 意図分類

    /// LLM 呼び出し前のキーワード先読み判定。確信度が高いケースのみ返し、それ以外は nil で LLM に委ねる。
    private static func keywordPrefilter(_ text: String) -> QueryIntent? {
        let paymentKeywords   = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "キャッシュレス", "支払い方法"]
        let paymentExclusions = ["おすすめ", "変化", "推移", "増えた", "減った", "変わった"]
        let weekdayKeywords   = ["月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜", "曜日", "週末", "平日"]
        let necessityCompound = ["必要支出", "便利支出", "贅沢支出", "必要度"]
        let adviceTriggers    = ["節約", "削減", "見直し", "改善", "減らす", "コツ", "アドバイス"]

        // 1. payment: 支払い方法固有語 ── 推薦・変化系は除外して LLM に委ねる
        if paymentKeywords.contains(where: { text.contains($0) }) {
            if !paymentExclusions.contains(where: { text.contains($0) }) {
                return .payment
            }
        }
        // 2. weekday: 曜日名・週末・平日
        if weekdayKeywords.contains(where: { text.contains($0) }) { return .weekday }

        // 3. necessity: 複合語のみ（単体の「必要」は対象外）
        if necessityCompound.contains(where: { text.contains($0) }) { return .necessity }

        // 4. category: カテゴリ名あり かつ アドバイストリガーなし
        let hasAdviceTrigger = adviceTriggers.contains(where: { text.contains($0) })
        if !hasAdviceTrigger {
            if allCategories.contains(where: { text.contains($0) }) { return .category }
        }

        return nil
    }

    private func classifyIntent(userText: String, modelContainer: MLXLMCommon.ModelContainer) async throws -> QueryIntent {
        // キーワード先読みで確信度高く判定できる場合は LLM をスキップ
        if let prefiltered = Self.keywordPrefilter(userText) {
            #if DEBUG
            print("[AdviceLLM]   キーワード先読み → \(prefiltered.rawValue)（LLMスキップ）")
            #endif
            return prefiltered
        }

        let prompt = """
        /no_think
        以下の質問を分類し、JSONオブジェクトのみを出力してください。説明は不要です。

        有効なインテント: advice, overview, category, trend, necessity, payment, weekday, help, offtopic

        - advice   : 節約・出費削減アドバイスを求める（例: 節約のコツを教えて、一番無駄な出費はどこ?、どこを削減すべき?）
        - overview : 支出について大まかに知りたい、支出のスコアを知りたい、支出を評価してほしい（例: 全体的な傾向は?、家計は健全?）
        - category : 特定カテゴリ(\(Self.allCategories.joined(separator: "、")))の金額・詳細を知りたい（例: 今月の食費は?、食費はどのくらい?、交通費について教えて、コンビニにいくら使った?、スマホ代は?）
        - trend    : 時系列・月別の推移を知りたい、時系列で比較したい（例: 先月の支出は?、月ごとの変化は?、支出傾向の推移を教えて、クレカと現金の支払いはどう変化した?）
        - necessity: 必要度(必要・便利・贅沢)別支出を知りたい（例: 贅沢支出はどれくらい?、必要支出の割合は?、先月の便利支出の金額を教えて）
        - payment  : 自分の支払い方法の実績・割合を知りたい（例: 現金とカードどちらが多い?、QRコード決済の割合は?）※カードや決済サービスの推薦・比較はofftopic
        - weekday  : 曜日の傾向を知りたい（例: 何曜日の支出が多い?）
        - help     : このAIの機能・使い方を知りたい（例: 何ができる?、どういうアプリ？）
        - offtopic : 家計・支出と無関係な質問、または金融商品の推薦・比較（例: 明日の天気は?、最近のニュースは？、おすすめのクレジットカードは?、ダイエット方法は?）

        【分類例】
        Q: 節約のコツを教えて → {"intent": "advice"}
        Q: 今月の合計支出はいくら？ → {"intent": "overview"}
        Q: 食費はどれくらい使った？ → {"intent": "category"}
        Q: コンビニにどのくらい使ってる？ → {"intent": "category"}
        Q: スマホ代は？ → {"intent": "category"}
        Q: 先月と今月の支出を比べて → {"intent": "trend"}
        Q: 毎月どのくらい使っている？ → {"intent": "trend"}
        Q: クレカと現金の支払いはどう変化した？ → {"intent": "trend"}
        Q: 贅沢支出はどれくらい？ → {"intent": "necessity"}
        Q: 現金とカードどちらが多い？ → {"intent": "payment"}
        Q: 何曜日に一番使っている？ → {"intent": "weekday"}
        Q: このAIで何ができる？ → {"intent": "help"}
        Q: おすすめのレシピを教えて → {"intent": "offtopic"}
        Q: おすすめのクレジットカードは？ → {"intent": "offtopic"}

        重要: {"intent": "advice"} のような有効なJSONのみを出力してください。上記のインテントから一つを選択してください。

        質問: \(userText)
        回答:
        """

        #if DEBUG
        print("[AdviceLLM] 🔍 分類プロンプト送信中（maxTokens=50）...")
        #endif

        let raw = try await modelContainer.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]])
            )
            var params = GenerateParameters()
            params.maxTokens = 50
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
        let intent = QueryIntent.parse(from: cleaned)

        #if DEBUG
        print("[AdviceLLM]   クリーニング後: \"\(cleaned)\"")
        print("[AdviceLLM]   解釈結果: \(intent != .overview || cleaned.contains("\"intent\"") ? "✅ \(intent.rawValue)" : "⚠️ JSONパース失敗 → .overview にフォールバック")")
        #endif

        return intent
    }

    // MARK: - Stage 2: システムプロンプト構築

    private func buildSystemPrompt(receipts: [SavedReceipt], intent: QueryIntent) -> String {
        let sections = intent.sections

        #if DEBUG
        print("[AdviceLLM] 📝 buildSystemPrompt: intent=\(intent.rawValue) sections=[\(sections.map { $0.rawValue }.joined(separator: ", "))]")
        #endif

        // offtopic: 家計と無関係な質問、またはAI自身への質問
        if intent == .offtopic {
            return """
            あなたはAI家計ナビの節約AIです。登録されたレシートをもとに家計・支出に関する質問に答えます。
            節約アドバイス、支出全体のサマリー、カテゴリ別・月別・曜日別の支出集計、支払い方法の確認ができます。

            # 命令文：
            ユーザーの質問を確認し、以下の方針で回答してください。
            - このAIの機能・使い方を聞いている場合（例: 何ができる？、使い方は？、どんな質問に答えられる？）は、上記の機能を簡潔に説明してください。
            - 家計・支出と全く無関係な質問（例: 天気、料理、ダイエット、ニュース）は、回答できないことを丁寧に伝え、家計や節約についての質問を促してください。

            # 回答の基本原則（最優先）：
            1. **簡潔な回答**: 回答は150字以内で。
            2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
            """
        }

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
        1. **数値の透明性**: 質問に直接関係する数値のみを引用し、金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
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

        let allCategories = Self.allCategories
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

        // 月別実数値
        let monthlyLines = sortedMonths.map { key -> String in
            let amount = monthlyGroups[key]?.reduce(0) { $0 + $1.total } ?? 0
            let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
            return "   - \(key): \(amount)円（全体の\(pct)%）"
        }.joined(separator: "\n")

        // 時系列×必要度クロス集計
        let trendByNecessityLines = sortedMonths.map { key -> String in
            let monthReceipts = monthlyGroups[key] ?? []
            let monthTotal = monthReceipts.reduce(0) { $0 + $1.total }
            let necGroups = Dictionary(grouping: monthReceipts) { $0.necessity }
            let necParts = ["必要", "便利", "贅沢"].map { nec -> String in
                let v = necGroups[nec]?.reduce(0) { $0 + $1.total } ?? 0
                let pct = monthTotal > 0 ? Int(Double(v) / Double(monthTotal) * 100) : 0
                return "\(nec) \(v)円(\(pct)%)"
            }.joined(separator: "、")
            return "   - \(key)（\(monthTotal)円）: \(necParts)"
        }.joined(separator: "\n")

        // 時系列×カテゴリクロス集計
        let trendByCategoryLines = sortedMonths.map { key -> String in
            let monthReceipts = monthlyGroups[key] ?? []
            let monthTotal = monthReceipts.reduce(0) { $0 + $1.total }
            let catGroups = Dictionary(grouping: monthReceipts) { $0.category }
            let catParts = allCategories.compactMap { cat -> String? in
                let v = catGroups[cat]?.reduce(0) { $0 + $1.total } ?? 0
                guard v > 0 else { return nil }
                let pct = monthTotal > 0 ? Int(Double(v) / Double(monthTotal) * 100) : 0
                return "\(cat) \(v)円(\(pct)%)"
            }.joined(separator: "、")
            return "   - \(key)（\(monthTotal)円）: \(catParts.isEmpty ? "データなし" : catParts)"
        }.joined(separator: "\n")

        // 曜日×必要度クロス集計
        let weekdayByNecessityLines = (1...7).map { wd -> String in
            let wdReceipts = weekdayGroups[wd] ?? []
            let wdTotal = wdReceipts.reduce(0) { $0 + $1.total }
            let necGroups = Dictionary(grouping: wdReceipts) { $0.necessity }
            let necParts = ["必要", "便利", "贅沢"].map { nec -> String in
                let v = necGroups[nec]?.reduce(0) { $0 + $1.total } ?? 0
                let pct = wdTotal > 0 ? Int(Double(v) / Double(wdTotal) * 100) : 0
                return "\(nec) \(v)円(\(pct)%)"
            }.joined(separator: "、")
            return "   - \(weekdayNames[wd])曜日（\(wdTotal)円）: \(necParts)"
        }.joined(separator: "\n")

        // 曜日×カテゴリクロス集計
        let weekdayByCategoryLines = (1...7).map { wd -> String in
            let wdReceipts = weekdayGroups[wd] ?? []
            let wdTotal = wdReceipts.reduce(0) { $0 + $1.total }
            let catGroups = Dictionary(grouping: wdReceipts) { $0.category }
            let catParts = allCategories.compactMap { cat -> String? in
                let v = catGroups[cat]?.reduce(0) { $0 + $1.total } ?? 0
                guard v > 0 else { return nil }
                let pct = wdTotal > 0 ? Int(Double(v) / Double(wdTotal) * 100) : 0
                return "\(cat) \(v)円(\(pct)%)"
            }.joined(separator: "、")
            return "   - \(weekdayNames[wd])曜日（\(wdTotal)円）: \(catParts.isEmpty ? "支出なし" : catParts)"
        }.joined(separator: "\n")

        // 支出上位カテゴリ Top3
        let topCategoryLines = allCategories
            .map { cat -> (String, Int) in
                let amount = categoryGroupsAll[cat]?.reduce(0) { $0 + $1.total } ?? 0
                return (cat, amount)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { cat, amount -> String in
                let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
                return "   - \(cat)：\(amount)円（総支出の\(pct)%）"
            }
            .joined(separator: "\n")

        // 必要度×カテゴリクロス集計（必要度視点：各必要度の上位カテゴリ）
        let necessityByCategoryLines = ["必要", "便利", "贅沢"].map { nec -> String in
            let necItems = necessityGroups[nec] ?? []
            let necTotal = necItems.reduce(0) { $0 + $1.total }
            let necPct = totalAmount > 0 ? Int(Double(necTotal) / Double(totalAmount) * 100) : 0
            let catGroups = Dictionary(grouping: necItems) { $0.category }
            let topCats = allCategories
                .compactMap { cat -> (String, Int)? in
                    let v = catGroups[cat]?.reduce(0) { $0 + $1.total } ?? 0
                    return v > 0 ? (cat, v) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
                .map { cat, amount -> String in
                    let pct = necTotal > 0 ? Int(Double(amount) / Double(necTotal) * 100) : 0
                    return "\(cat) \(amount)円(\(pct)%)"
                }
                .joined(separator: "、")
            return "   - \(nec)（\(necTotal)円, 総支出の\(necPct)%）: 上位カテゴリ → \(topCats.isEmpty ? "支出なし" : topCats)"
        }.joined(separator: "\n")

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
            weekdayLines: weekdayLines,
            monthlyLines: monthlyLines,
            trendByNecessityLines: trendByNecessityLines,
            trendByCategoryLines: trendByCategoryLines,
            weekdayByNecessityLines: weekdayByNecessityLines,
            weekdayByCategoryLines: weekdayByCategoryLines,
            topCategoryLines: topCategoryLines,
            necessityByCategoryLines: necessityByCategoryLines
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
        ・合計支出：\(ctx.totalAmount)円（\(ctx.recordCount)件）
        ・月平均支出：\(ctx.avgMonthlyTotal)円
        ・支出増減傾向：\(ctx.spendingTrendMessage)

        【支出健全度スコア】
        ・スコア：\(ctx.spendingScore)点
        ・\(ctx.scoreMessage)

        【必要度別内訳】
        \(ctx.necessityLines)

        【支出上位カテゴリ Top3】
        \(ctx.topCategoryLines)
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

        【月別支出】
        \(ctx.monthlyLines)

        【月別×必要度クロス集計】
        \(ctx.trendByNecessityLines)

        【月別×カテゴリクロス集計】
        \(ctx.trendByCategoryLines)
        """
    }

    private func sectionWeekday(_ ctx: AnalysisContext) -> String {
        """
        ## 曜日別支出
        \(ctx.weekdayTrendMessage)

        【曜日別内訳】
        \(ctx.weekdayLines)

        【曜日×必要度クロス集計】
        \(ctx.weekdayByNecessityLines)

        【曜日×カテゴリクロス集計】
        \(ctx.weekdayByCategoryLines)
        """
    }

    private func sectionNecessity(_ ctx: AnalysisContext) -> String {
        """
        ## 必要度別支出
        【必要度別内訳】
        \(ctx.necessityLines)

        【必要度×カテゴリクロス集計】
        \(ctx.necessityByCategoryLines)

        【月別×必要度クロス集計（必要度×時系列）】
        \(ctx.trendByNecessityLines)

        【曜日別×必要度クロス集計（必要度×曜日）】
        \(ctx.weekdayByNecessityLines)
        """
    }

    private func sectionCategory(_ ctx: AnalysisContext) -> String {
        """
        ## カテゴリ別支出
        【カテゴリ別内訳（カテゴリ×必要度）】
        \(ctx.categoryLines)

        【月別×カテゴリクロス集計（カテゴリ×時系列）】
        \(ctx.trendByCategoryLines)

        【曜日別×カテゴリクロス集計（カテゴリ×曜日）】
        \(ctx.weekdayByCategoryLines)
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

    private func buildConversationMessages(system: String, userText: String) -> [[String: any Sendable]] {
        [
            ["role": "system", "content": system],
            ["role": "user", "content": "/no_think \(userText)"]
        ]
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
