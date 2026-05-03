# AI家計ナビ

レシート画像をスキャンして支出を自動記録・分析するiOSアプリ。オンデバイスLLMによる解析と節約アドバイスが特徴です。

## 特徴

- **レシート自動解析** — カメラ撮影またはライブラリから画像を選択し、VisionフレームワークのOCRとLLMで品目・金額・必要度を自動抽出
- **オンデバイスAI** — Qwen3-1.7B-4bitモデルをデバイス上で動作させるため、データが外部に送信されない
- **支出分析** — 月別・カテゴリ別のグラフで支出傾向を可視化（Chartsフレームワーク使用）
- **節約アドバイス** — 過去の支出データをもとにAIがチャット形式で節約提案を行う
- **必要度スコア** — 各出費を「必要 / 便利 / 贅沢」の3段階で分類し、バランスを管理

## 技術スタック

| 技術 | 用途 |
|---|---|
| SwiftUI | UI構築 |
| SwiftData | レシートデータの永続化 |
| Vision | レシート画像のOCR |
| MLXLLM / MLXLMCommon | オンデバイスLLM推論 |
| Charts | 分析画面のグラフ描画 |
| Qwen3-1.7B-4bit | LLMモデル（HuggingFaceからダウンロード） |

## 動作環境

- iOS 17.0 以上
- Xcode 16 以上
- Apple Silicon Mac（ビルド環境として推奨）

## セットアップ

```bash
git clone <repository-url>
cd AIKakeiNavi
open AIKakeiNavi.xcodeproj
```

Xcode でスキームを選択し、実機またはシミュレータでビルド・実行してください。

> **Note:** オンデバイスAI機能を使用する場合は、アプリ内の「設定」画面からモデルのダウンロードが必要です（約1GB）。

## 画面構成

| 画面 | 概要 |
|---|---|
| レシート登録 | カメラ・ライブラリからレシートを読み取り保存 |
| 履歴 | 保存済みレシートの一覧・編集・削除 |
| 分析 | 月別・カテゴリ別グラフによる支出の可視化 |
| 節約AI | 支出データをもとにしたチャット形式のアドバイス |
| 設定 | 必要度スコアの目標比率・AI分析期間などの設定 |

## プロジェクト構成

```
AIKakeiNavi/
├── App/            # エントリポイント
├── Models/         # SwiftDataモデル・LLMレスポンス構造体
├── Services/       # LLM推論・モデルDL・AI管理サービス
├── Views/          # 各画面のSwiftUIビュー
└── Components/     # 共通UIコンポーネント
```

## オープンソースライセンス

このアプリは以下のオープンソースソフトウェアを使用しています。

| ライブラリ / モデル | ライセンス |
|---|---|
| [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) | Apache 2.0 |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | MIT |
| [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | MIT |

## ライセンス

MIT
