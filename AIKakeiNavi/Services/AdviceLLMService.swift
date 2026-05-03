import Foundation
import MLXLLM
import MLXLMCommon
import SwiftData
import Tokenizers

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
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

    func sendMessage(userText: String, receipts: [SavedReceipt]) async {
        guard !userText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        messages.append(ChatMessage(role: "user", content: userText))
        isRunning = true
        downloadProgress = 0.0
        statusText = "準備中..."
        streamingResponse = ""
        dataWarningMessage = ""

        let systemPrompt = buildSystemPrompt(receipts: receipts)
        #if DEBUG
        print(systemPrompt)
        #endif
        let conversationPrompt = buildConversationPrompt(system: systemPrompt)

        var finalResponse = ""

        do {
            let config = ModelConfiguration(directory: AIServiceManager.shared.localModelURL)

            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            )

            self.statusText = "回答生成中..."
            self.downloadProgress = 1.0

            let result = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(
                    input: .init(prompt: conversationPrompt)
                )

                var params = GenerateParameters()
                params.maxTokens = 1200

                var accumulated = ""

                let generateResult: GenerateResult = try MLXLMCommon.generate(
                    input: input,
                    parameters: params,
                    context: context,
                    didGenerate: { tokens in
                        let piece = context.tokenizer.decode(tokens: tokens)
                        accumulated += piece

                        let snapshot = accumulated
                        Task { @MainActor in
                            // <think>...</think> ブロックを画面に表示しない
                            // 思考中は「思考中...」と表示し、</think>以降のみ表示する
                            if snapshot.contains("</think>") {
                                // 思考完了: </think>以降の本文のみ表示
                                let parts = snapshot.components(separatedBy: "</think>")
                                var display = parts.last ?? snapshot
                                let stopTokens = ["<|user|>", "<|system|>", "<|end|>", "</s>"]
                                for token in stopTokens {
                                    if let range = display.range(of: token) {
                                        display = String(display[..<range.lowerBound])
                                    }
                                }
                                self.streamingResponse = display.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else if snapshot.contains("<think>") {
                                // 思考プロセス中: 専用メッセージを表示
                                self.streamingResponse = "思考中..."
                            } else {
                                // 通常出力
                                var display = snapshot
                                let stopTokens = ["<|user|>", "<|system|>", "<|end|>", "</s>"]
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
                return generateResult.output
            }

            finalResponse = cleanResponse(result)

        } catch {
            finalResponse = "回答の生成中にエラーが発生しました。もう一度お試しください。"
        }

        // ダウンロードが完了していればフラグを同期
        if !finalResponse.contains("エラー") {
            AIServiceManager.shared.completeDownload()
        }

        #if DEBUG
        print("\n================ LLM ADVISOR OUTPUT ================")
        print(finalResponse)
        print("====================================================\n")
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

    // MARK: - Prompt Building

    private func buildSystemPrompt(receipts: [SavedReceipt]) -> String {
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
        let totalAmount = target.reduce(0) { $0 + $1.total }

        if recordCount == 0 {
            dataWarningMessage = "支出データがまだ記録されていません。レシートを登録するとアドバイスの精度が上がります。"
            return """
            # 命令文：
            ユーザーはまだ支出データを一件も登録していません。支出レポートは存在しません。
            支出データが登録されていないため、支出に基づいたアドバイスや分析はできないことをユーザーに伝えてください。
            レシートを登録するよう、丁寧に促してください。

            # 回答の基本原則（最優先）：
            1. **簡潔な回答**: 回答は200字以内で簡潔に。
            2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
            """
        } else if recordCount < 5 {
            dataWarningMessage = "データがまだ\(recordCount)件のみです。より多くのレシートを登録すると精度の高いアドバイスができます。"
        }

        let necessityGroups = Dictionary(grouping: target) { $0.necessity }
        let paymentGroups = Dictionary(grouping: target) { $0.paymentMethod }

        let cashTotal = paymentGroups["現金"]?.reduce(0) { $0 + $1.total } ?? 0
        let cashPct = totalAmount > 0 ? Int(Double(cashTotal) / Double(totalAmount) * 100) : 0

        // 支出内の必要度比率をスコア化（目標比率はユーザー設定、デフォルト62.5%）
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
                scoreMessage = "必要支出の割合が高めです。そのため、固定費などの必要な支出を見直すか、あるいは少しの贅沢を取り入れて、日々の生活に時間や心のゆとりを持たせることも検討してみてください。"
            } else {
                scoreMessage = "必要支出の割合が低く、便利や贅沢への支出が目立ちます。そのため、手間を惜しまず自炊を取り入れたり、贅沢を少し控えることで、より健全な家計に近づけることができます。"
            }
        } else {
            scoreMessage = "支出のコントロール権を「自分の欲望（便利・贅沢）」に奪われつつあります。家計防衛の観点から赤信号です。"
        }

        let convenienceTotal = necessityGroups["便利"]?.reduce(0) { $0 + $1.total } ?? 0
        let luxuryTotal = necessityGroups["贅沢"]?.reduce(0) { $0 + $1.total } ?? 0
        let convRatio = totalAmount > 0 ? (Double(convenienceTotal) / Double(totalAmount) * 100) : 0
        let luxRatio = totalAmount > 0 ? (Double(luxuryTotal) / Double(totalAmount) * 100) : 0

        var savingPotentials: [String] = []
        
        // 便利支出の上位カテゴリ抽出とアドバイス生成
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
        
        // 贅沢支出の上位カテゴリ抽出とアドバイス生成
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
        
        let savingPotentialMessage = savingPotentials.isEmpty ? "特にありません。アドバイスをする場合は、大きな節約余地がないことをユーザに明示して下さい。" : savingPotentials.joined(separator: "\n")

        // --- 支出推移の分析ロジック ---
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

        var spendingTrendMessage = ""
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

        // --- 詳細データの構築 ---
        // 1. 必要度別
        let necessityLines = ["必要", "便利", "贅沢"].map { nec -> String in
            let amount = necessityGroups[nec]?.reduce(0) { $0 + $1.total } ?? 0
            let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
            return "   - \(nec)：\(amount)円（総支出の\(pct)%）"
        }.joined(separator: "\n")

        // 2. カテゴリ別（支出ゼロも含む）
        let allCategories = ["食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費", "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費", "サブスク費", "勉強費", "その他"]
        let categoryGroups = Dictionary(grouping: target) { $0.category }
        let categoryLines = allCategories.map { cat -> String in
            let items = categoryGroups[cat] ?? []
            let catTotal = items.reduce(0) { $0 + $1.total }
            let catPct = totalAmount > 0 ? Int(Double(catTotal) / Double(totalAmount) * 100) : 0
            
            let necInCat = Dictionary(grouping: items) { $0.necessity }
            let necDetails = ["必要", "便利", "贅沢"].map { nec -> String in
                let v = necInCat[nec]?.reduce(0) { $0 + $1.total } ?? 0
                if v > 0 {
                    let localPct = Int(Double(v) / Double(catTotal) * 100)
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

        // 3. 支払い方法別（主要なものは支出ゼロでも出す）
        let allPayments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
        let paymentLines = allPayments.map { method -> String in
            let amount = paymentGroups[method]?.reduce(0) { $0 + $1.total } ?? 0
            let pct = totalAmount > 0 ? Int(Double(amount) / Double(totalAmount) * 100) : 0
            return "   - \(method)：\(amount > 0 ? "\(amount)円" : "支出なし")（総支出の\(pct)%）"
        }.joined(separator: "\n")

        // 4. 曜日別
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

        return """
        # 命令文：
        以下のユーザーの支出レポートから情報を抜き出すことで、ユーザの質問に回答して下さい。
        
        # 支出レポート：
        対象期間（\(periodLabel)）の合計支出は\(totalAmount)円（\(recordCount)件）です。
        ユーザの全体的な支出傾向のスコアは\(spendingScore)点であり、\(scoreMessage)
        大きな節約余地は、\(savingPotentialMessage)
        支払い方法を見ると、\(paymentMethodMessage)
        支出の推移としては、\(spendingTrendMessage)
        曜日別の傾向としては、\(weekdayTrendMessage)
        
        ## 支出詳細データ
        【必要度別】
        \(necessityLines)

        【カテゴリ別】
        \(categoryLines)

        【支払い方法別】
        \(paymentLines)

        【曜日別】
        \(weekdayLines)

        # 回答の基本原則（最優先）：
        1. **数値の透明性**: 金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
        2. **簡潔な回答**: 回答は300字以内で簡潔に。
        3. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
        4. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。
        """
    }


    // 便利支出（ついつい楽をしてしまう支出）へのアドバイス
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

    // 贅沢支出（見栄や快楽のための支出）へのアドバイス
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

    private func buildConversationPrompt(system: String) -> String {
        let recentMessages = recentHistory()
        var prompt = "<|system|>\n\(system)\n"
        for msg in recentMessages {
            let role = msg.role == "user" ? "user" : "assistant"
            prompt += "<|\(role)|>\n\(msg.content)\n"
        }
        prompt += "<|assistant|>\n"
        return prompt
    }

    private func recentHistory() -> [ChatMessage] {
        let maxMessages = maxHistoryTurns * 2
        if messages.count <= maxMessages { return messages }
        return Array(messages.suffix(maxMessages))
    }

    private func cleanResponse(_ text: String) -> String {
        var cleaned = text

        // Qwen3等のThinkingモデルの<think>...</think>ブロックを除去
        // 最後の</think>より後ろの部分のみを最終回答として使用する
        if cleaned.contains("</think>") {
            let parts = cleaned.components(separatedBy: "</think>")
            cleaned = parts.last ?? cleaned
        } else if let thinkStart = cleaned.range(of: "<think>") {
            // </think>がないまま終わった場合（途中で打ち切り）は<think>以前を使う
            cleaned = String(cleaned[..<thinkStart.lowerBound])
        }

        // モデル共通のストップトークンを除去
        let stopTokens = ["<|user|>", "<|system|>", "<|end|>", "</s>"]
        for token in stopTokens {
            if let range = cleaned.range(of: token) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
