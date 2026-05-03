import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var aiManager = AIServiceManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 80))
                .foregroundColor(.blue)
                .padding(.top, 40)

            VStack(spacing: 12) {
                Text("AI機能を有効にしますか？")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("レシートの自動読み取りや、AIアドバイザー機能を利用するには、約1GBのAIモデルのダウンロードが必要です。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Label("解析・アドバイスはすべて端末内で処理（完全プライベート）", systemImage: "lock.shield.fill")
                    Label("ダウンロード元：HuggingFace（huggingface.co）／1回のみ", systemImage: "arrow.down.circle")
                    Label("一度ダウンロードすればオフラインでも使用可能", systemImage: "wifi.slash")
                    Label("毎月のAPI利用料・通信料なし", systemImage: "checkmark.seal.fill")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            }

            if aiManager.isDownloading {
                VStack(spacing: 10) {
                    ProgressView(value: aiManager.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 250)
                    Text(aiManager.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if aiManager.downloadFailed {
                VStack(spacing: 16) {
                    Text(aiManager.statusText)
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button(action: { aiManager.startParallelDownload() }) {
                        Text("再試行する")
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 40)

                    Button("閉じる") { dismiss() }
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 16) {
                    Button(action: { aiManager.startParallelDownload() }) {
                        Text("ダウンロードして開始")
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 40)

                    Button("今はしない") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text("※Wi-Fi環境でのダウンロードを推奨します。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .interactiveDismissDisabled(aiManager.isDownloading)
        .onChange(of: aiManager.hasDownloadedModel) { _, downloaded in
            if downloaded { dismiss() }
        }
    }
}
