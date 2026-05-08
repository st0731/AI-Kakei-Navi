import Foundation
import MLXLLM
import MLXLMCommon

@MainActor
@Observable
class LLMService {
    var status = "未実行"
    var isRunning = false
    var downloadProgress: Double = 0.0

    var lastReceipt: ReceiptJSON?

    func processWithLLM(ocrText: String) async {
        self.isRunning = true
        self.downloadProgress = 0.0
        self.status = "準備中..."
        defer { self.isRunning = false }

        var finalResult = ""

        do {
            try Task.checkCancellation()

            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: AIServiceManager.shared.localModelURL,
                using: HuggingFaceTokenizerLoader()
            )

            try Task.checkCancellation()

            self.status = "解析中..."
            self.downloadProgress = 1.0

            let prompt = """
            /no_think
            # 命令文：
            以下のOCRデータから必要な情報を抽出し、以下の出力フォーマットに従って日本語で回答してください。
            特に「必要度」と「カテゴリ」は、以下の定義に従って厳格に判定してください。

            # 1. 必要度 (necessity) の判定基準：
            - 【必要】：生活維持に不可欠（スーパーの食材、医療、公共交通機関など）
            - 【便利】：時短や快適さのために課金（コンビニ、ドラッグストア、タクシー、ファストフードなど）
            - 【贅沢】：楽しむための嗜好品や娯楽（レストラン、カフェ、ブランド品、書店、映画など）

            # 2. カテゴリ (category) のリスト：
            食費、服・美容費、日用品・雑貨費、交通・移動費、通信費、水道光熱費、住居費、医療・健康費、趣味・娯楽費、交際費、サブスク費、勉強費、その他

            # 3. 支払い方法リスト：
            現金, クレジットカード, QRコード決済, 電子マネー, その他

            # ヒント：
            ・OCRデータには営業時間や宣伝などの出力するべきでない情報が含まれている場合があるのでそれらは無視してください。
            ・¥や円が書いていない数値は商品コードなどの可能性が高いので無視してください。
            ・合計金額は合計の後に書かれていることが多いです。
            ・判定したカテゴリが、購入された商品リストの内容（例：バーガー、コーヒー等）と矛盾していないか確認してください。商品内容を最終的な根拠にしてください。

            # 出力フォーマット(JSON以外出力禁止)：
            {
              "date": "yyyy/MM/dd",
              "necessity": "必要 or 便利 or 贅沢",
              "category": "カテゴリ名",
              "total": 合計金額(整数),
              "payment_method": "支払い方法"
            }

            OCRデータ:
            \(ocrText)
            """

            let result = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(
                    input: .init(messages: [["role": "user", "content": prompt]])
                )

                var params = GenerateParameters()
                params.maxTokens = 200

                let generateResult: GenerateResult = try MLXLMCommon.generate(
                    input: input,
                    parameters: params,
                    context: context,
                    didGenerate: { tokens in
                        return .more
                    }
                )

                return generateResult.output
            }
            
            #if DEBUG
            print("\n================ LLM RECEIPT ANALYSIS OUTPUT (RAW) ================")
            print(result)
            print("====================================================================\n")
            #endif

            // Qwen3の<think>ブロックを除去し、JSON部分のみ抽出
            var cleanedResult = result
            if cleanedResult.contains("</think>") {
                let parts = cleanedResult.components(separatedBy: "</think>")
                cleanedResult = parts.last ?? cleanedResult
            } else if let thinkStart = cleanedResult.range(of: "<think>") {
                cleanedResult = String(cleanedResult[..<thinkStart.lowerBound])
            }
            cleanedResult = cleanedResult.trimmingCharacters(in: .whitespacesAndNewlines)

            #if DEBUG
            print("================ LLM RECEIPT ANALYSIS OUTPUT (CLEANED) ================")
            print(cleanedResult)
            print("========================================================================\n")
            #endif

            finalResult = cleanedResult
            self.status = cleanedResult

        } catch is CancellationError {
            self.status = "未実行"
            return
        } catch {
            #if DEBUG
            print("LLM ERROR: \(error)")
            print("LLM ERROR TYPE: \(type(of: error))")
            #endif
            self.status = "解析中にエラーが発生しました。もう一度お試しください。"
        }

        if !finalResult.isEmpty {
            parseAndSave(jsonString: finalResult)
        }
    }

    private func parseAndSave(jsonString: String) {
        guard let jsonData = extractJSON(from: jsonString) else {
            self.status = "JSONの抽出に失敗しました"
            return
        }

        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ReceiptJSON.self, from: jsonData)
            #if DEBUG
            print("---------- decoded ----------")
            print(decoded)
            #endif
            self.lastReceipt = decoded
            self.status = "解析完了：\(decoded.total)円"
        } catch {
            #if DEBUG
            print("Parse Error: \(error)")
            #endif
            self.status = "データのパースに失敗しました"
        }
    }

    private func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return text.data(using: .utf8)
        }

        guard start < end else {
            return text.data(using: .utf8)
        }

        let jsonString = String(text[start...end])
        return jsonString.data(using: .utf8)
    }
}
