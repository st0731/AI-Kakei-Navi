import Foundation
import SwiftUI
import UIKit
import Combine
import Metal

@MainActor
class AIServiceManager: ObservableObject {
    static let shared = AIServiceManager()
    
    @AppStorage("isAIEnabled") var isAIEnabled: Bool = false
    @AppStorage("hasDownloadedModel") var hasDownloadedModel: Bool = false
    
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var statusText: String = ""
    @Published var downloadFailed: Bool = false
    
    let modelID = "mlx-community/Qwen3-1.7B-4bit"

    var localModelURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface/models/\(modelID)")
    }

    private init() {
        let lastID = UserDefaults.standard.string(forKey: "lastModelID")
        if lastID != modelID {
            hasDownloadedModel = false
            UserDefaults.standard.set(modelID, forKey: "lastModelID")
        }
    }
    
    func checkModelExists() -> Bool {
        return hasDownloadedModel
    }

    func completeDownload() {
        self.hasDownloadedModel = true
        self.isAIEnabled = true
        self.isDownloading = false
        self.downloadProgress = 1.0
        self.statusText = "準備完了"
    }

    func startParallelDownload() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadFailed = false
        downloadProgress = 0
        statusText = "準備中..."

        let id = modelID
        Task {
            do {
                let downloader = ParallelModelDownloader()
                try await downloader.download(modelID: id) { progress, status in
                    Task { @MainActor in
                        AIServiceManager.shared.downloadProgress = progress
                        AIServiceManager.shared.statusText = status
                    }
                }
                self.completeDownload()
            } catch let urlError as URLError {
                self.isDownloading = false
                self.downloadFailed = true
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    self.statusText = "インターネット接続がありません。Wi-Fiまたはモバイル通信を確認してください。"
                case .timedOut:
                    self.statusText = "通信タイムアウトが発生しました。通信環境の良い場所で再試行してください。"
                case .cannotDecodeContentData:
                    self.statusText = "ダウンロードされたファイルが破損しています。再試行してください。"
                default:
                    self.statusText = "ダウンロードに失敗しました。通信環境を確認して再試行してください。"
                }
            } catch {
                self.isDownloading = false
                self.downloadFailed = true
                if error.localizedDescription.contains("space") || error.localizedDescription.contains("disk") {
                    self.statusText = "端末のストレージ空き容量が不足しています。空き容量を確保してから再試行してください。"
                } else {
                    self.statusText = "ダウンロードに失敗しました。通信環境を確認して再試行してください。"
                }
            }
        }
    }
    
    func prewarmServices() {
        Task.detached(priority: .high) {
            _ = MTLCreateSystemDefaultDevice()
            // 数値フォーマッタは初回が重いため先にロード
            _ = 1000.formatted(.number)
            _ = LLMService.self
        }
        warmUpUISubsystems()
    }

    // キーボードプロセスは初回呼び出しが非常に重いため、スプラッシュ画面中に
    // UITextFieldを一時的にウィンドウへ追加してバックグラウンド起動させる。
    // alpha=0.01 で不可視、スプラッシュ終了後に除去。
    private func warmUpUISubsystems() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first
        else { return }

        let tf = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        tf.alpha = 0.01
        window.addSubview(tf)
        // DispatchQueue.main.async でビュー追加の次のランループサイクルに実行
        DispatchQueue.main.async {
            tf.becomeFirstResponder()
            tf.resignFirstResponder()
            // スプラッシュ表示期間（2.5秒）はキャッシュ定着のために保持してから除去
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                tf.removeFromSuperview()
            }
        }
    }
}
