import SwiftUI

struct SettingsView: View {
    @AppStorage("necessityTargetRatio") private var targetRatio: Double = 62.5
    @AppStorage("adviceAnalysisPeriod") private var advicePeriod: String = AdviceAnalysisPeriod.threeMonths.rawValue

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - スコア設定
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("「必要な支出」(食費・医療・交通など生活に欠かせないもの)と、「その他の支出」(趣味・娯楽・サブスクなど)の理想的な割合を設定します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("理想的な割合に基づいてスコアが計算され、節約AIの節約提案に反映されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("理想の必要支出割合")
                            Spacer()
                            Text(String(format: "%.1f%%", targetRatio))
                                .bold()
                                .foregroundStyle(.blue)
                        }
                        Slider(value: $targetRatio, in: 40...90, step: 0.5)
                            .tint(.blue)
                        HStack {
                            Text("40%")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("90%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    Button("デフォルトに戻す（62.5%）") {
                        targetRatio = 62.5
                    }
                    .font(.footnote)
                    .foregroundStyle(.blue)
                } header: {
                    Text("支出スコアの設定")
                }

                // MARK: - 節約AI設定
                Section {
                    Text("節約AIがアドバイスを生成する際に参照するレシートの期間を設定します。期間を短くするほど直近の傾向が、長くするほど全体的な傾向が反映されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                    Picker("分析対象期間", selection: $advicePeriod) {
                        ForEach(AdviceAnalysisPeriod.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p.rawValue)
                        }
                    }
                } header: {
                    Text("節約AIの設定")
                }

                // MARK: - ライセンス
                Section("オープンソースライセンス") {
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("使用ライブラリ一覧", systemImage: "doc.plaintext")
                    }
                }

                // MARK: - 情報
                Section("情報") {
                    Link(destination: URL(string: "https://st0731.github.io/AI-Kakei-Navi/privacy")!) {
                        Label("プライバシーポリシー", systemImage: "lock.shield")
                    }
                    .foregroundStyle(.primary)

                    Link(destination: URL(string: "https://st0731.github.io/AI-Kakei-Navi/terms")!) {
                        Label("利用規約", systemImage: "doc.text")
                    }
                    .foregroundStyle(.primary)

                    Link(destination: URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSe3rI8B4OfYUH44n2T97RHnE2gz6DBmZ2rz1xCuIXrL7zJ0zw/viewform?usp=publish-editor")!) {
                        Label("お問い合わせ", systemImage: "envelope")
                    }
                    .foregroundStyle(.primary)

                    LabeledContent("バージョン", value: appVersion)
                }
            }
            .navigationTitle("設定")
        }
    }
}
