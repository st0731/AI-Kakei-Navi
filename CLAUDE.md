# AIKakeiNavi — プロジェクト構成メモ

ファイルの追加・削除・役割変更など根本的な変更があったときは、必要に応じてこのファイルを書き換えてください。
このファイルは、会話をリセットしても Claude がすぐにファイル構成を把握するためのものです。

---

## 概要

レシート画像をOCRで読み取り、オンデバイスLLM（Qwen3-1.7B-4bit）で解析して支出を記録・分析するiOSアプリ。
アプリ名は「AI家計ナビ」。SwiftUI + SwiftData + MLX で構成。

---

## ディレクトリ構成

```
AIKakeiNavi/
├── App/
│   └── AIKakeiNaviApp.swift          # @main エントリポイント。SwiftData の modelContainer を設定
│
├── Models/
│   ├── ReceiptJSON.swift             # LLM が返す JSON のデコード用構造体
│   └── SaveReceipt.swift             # SwiftData の永続化モデル（@Model class SavedReceipt）
│
├── Services/
│   ├── LLMService.swift              # レシートOCRテキスト → LLM解析 → ReceiptJSON を返すサービス
│   ├── AdviceLLMService.swift        # 節約アドバイス用チャット型LLMサービス（ストリーミング対応）
│   ├── AIServiceManager.swift        # AIの有効/無効・モデルDL状態を一元管理するシングルトン
│   └── ParallelModelDownloader.swift # HuggingFace からモデルファイルを並列ダウンロードする actor
│
├── Views/
│   ├── ContentView.swift             # タブバー（登録/履歴/分析/節約AI/設定）のルートビュー
│   ├── SplashView.swift              # 起動時スプラッシュ画面
│   │
│   ├── Receipt/
│   │   ├── ReceiptAnalysisView.swift # レシート画像選択（カメラ/ライブラリ）→ OCR → LLM解析 → 保存の一連フロー
│   │   ├── ReceiptEditView.swift     # 保存済みレシートの手動編集画面
│   │   └── ReceiptHistoryView.swift  # 保存済みレシート一覧（削除・手動編集も対応）
│   │
│   ├── Analytics/
│   │   ├── InsightAnalyticsView.swift # グラフ・集計表示画面（Charts フレームワーク使用）
│   │   └── AnalyticsViewModel.swift   # 集計ロジックを担う ObservableObject ViewModel
│   │
│   ├── Advice/
│   │   ├── AdviceView.swift          # 節約アドバイスAIとのチャット画面
│   │   └── ModelDownloadView.swift   # AI機能有効化・モデルダウンロード確認画面
│   │
│   └── Settings/
│       └── SettingsView.swift        # 必要度スコア目標比率・節約AI分析期間などのアプリ設定
│
├── Components/
│   ├── CardStyle.swift               # カード風背景を付ける ViewModifier
│   ├── FilterChip.swift              # フィルター選択用のチップ型ボタンコンポーネント
│   ├── LoadingOverlay.swift          # 処理中に表示するフルスクリーンオーバーレイ
│   └── NecessityColor.swift          # 「必要/便利/贅沢」に対応する Color 拡張
│
├── Assets.xcassets/
│   ├── AppIcon.appiconset/           # アプリアイコン
│   └── SplashIcon.imageset/          # スプラッシュ画面用アイコン
│
└── PrivacyInfo.xcprivacy             # プライバシーマニフェスト
```

---

## 主要な依存関係

- **SwiftData** — レシートデータの永続化
- **MLXLLM / MLXLMCommon** — オンデバイスLLM推論
- **Vision** — レシート画像のOCR
- **Charts** — 分析画面のグラフ描画
- **モデル** — `mlx-community/Qwen3-1.7B-4bit`（HuggingFace からダウンロード）
