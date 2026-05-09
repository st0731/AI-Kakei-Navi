#!/usr/bin/env python3
"""
test_current.py — AdviceLLMService.swift (現在の実装) を Python で忠実に再現し、多様なプロンプトでテスト

現在のSwift実装を正確に反映:
  Stage 1: LLMによる意図分類 JSON形式 {"intent": "xxx"}  maxTokens=50
  Stage 2: sections に応じたシステムプロンプト構築 → 回答生成 maxTokens=1200

インテント: advice, overview, category, trend, necessity, payment, weekday, help, offtopic

Usage:
  # LLM不使用: システムプロンプトの内容・セクション構成を確認
  python test_current.py --dry-run --pattern A

  # Stage 1のみ: LLM分類精度を計測
  python test_current.py --stage1

  # 完全パイプライン: Stage1+Stage2の回答をtxtに保存しテーブル表示
  python test_current.py --full --pattern A
  python test_current.py --full --pattern B --question "節約のアドバイスをして"
"""

import argparse
import datetime
import json
import os
import re
import sys
from dataclasses import dataclass

# ─────────────────────────────────────────────────────────────
# ContentFilter（Swift: ContentFilter.blockedKeywords）
# ─────────────────────────────────────────────────────────────
BLOCKED_KEYWORDS = ["仮想通貨", "ビットコイン", "暗号資産", "FX", "レバレッジ", "信用取引", "株式投資", "証券口座"]

def blocked_keyword(text: str):
    for kw in BLOCKED_KEYWORDS:
        if kw in text:
            return kw
    return None

# ─────────────────────────────────────────────────────────────
# QueryIntent（Swift: QueryIntent enum）
# ─────────────────────────────────────────────────────────────
VALID_INTENTS = {"advice", "overview", "category", "trend", "necessity", "payment", "weekday", "offtopic"}

# Swift: var sections: [QuerySection]
SECTIONS_MAP = {
    "advice":   ["summary", "saving"],
    "overview": ["summary"],
    "category": ["category"],
    "trend":    ["trend"],
    "necessity":["necessity"],
    "payment":  ["payment"],
    "weekday":  ["weekday"],
    "offtopic": [],          # 特殊: offtopicプロンプト固定
}

# Swift: classifyIntent の Stage 1 プロンプト（完全一致）
ALL_CATEGORIES = ["食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費", "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費", "サブスク費", "勉強費", "その他"]

STAGE1_PROMPT_TEMPLATE = """/no_think
以下の質問を分類し、JSONオブジェクトのみを出力してください。説明は不要です。

有効なインテント: advice, overview, category, trend, necessity, payment, weekday, offtopic

- advice   : 節約・出費削減アドバイスを求める（例: 節約のコツを教えて、一番無駄な出費はどこ?、どこを削減すべき?）
- overview : 支出について大まかに知りたい、支出のスコアを知りたい、支出を評価してほしい（例: 全体的な傾向は?、家計は健全?）
- category : 特定カテゴリ({categories})の金額・詳細を知りたい（例: 今月の食費は?、食費はどのくらい?、交通費について教えて）
- trend    : 時系列・月別の推移を知りたい、時系列で比較したい（例: 先月の支出は?、月ごとの変化は?、支出傾向の推移を教えて）
- necessity: 必要度(必要・便利・贅沢)別支出を知りたい（例: 贅沢支出はどれくらい?、必要支出の割合は?、先月の便利支出の金額を教えて）
- payment  : 支払い方法(現金、クレジットカード、QRコード決済、電子マネー)について知りたい（例: 現金とカードどちらが多い?）
- weekday  : 曜日の傾向を知りたい（例: 何曜日の支出が多い?）
- offtopic : 家計・支出と無関係な質問（例: 明日の天気は?、最近のニュースは？、食器の洗い方は？）

【分類例】
Q: 節約のコツを教えて → {{"intent": "advice"}}
Q: 今月の合計支出はいくら？ → {{"intent": "overview"}}
Q: 食費はどれくらい使った？ → {{"intent": "category"}}
Q: 先月と今月の支出を比べて → {{"intent": "trend"}}
Q: 毎月どのくらい使っている？ → {{"intent": "trend"}}
Q: 贅沢支出はどれくらい？ → {{"intent": "necessity"}}
Q: 現金とカードどちらが多い？ → {{"intent": "payment"}}
Q: 何曜日に一番使っている？ → {{"intent": "weekday"}}
Q: おすすめのレシピを教えて → {{"intent": "offtopic"}}

重要: {{"intent": "advice"}} のような有効なJSONのみを出力してください。上記のインテントから一つを選択してください。

質問: {question}
回答:"""

STAGE1_SYSTEM_MESSAGE = "あなたはAI家計ナビの質問分類AIです。家計・支出・節約に特化したアシスタントへの質問を分類します。ダイエット・料理・天気・ニュース・健康・投資など家計と無関係な話題はすべてofftopicです。"

def build_stage1_prompt(question: str) -> str:
    return STAGE1_PROMPT_TEMPLATE.format(
        categories="、".join(ALL_CATEGORIES),
        question=question,
    )

# ─────────────────────────────────────────────────────────────
# キーワード先読み判定（ハイブリッド方式）
# Swift 実装候補: classifyIntent の LLM 呼び出し前に適用
# ─────────────────────────────────────────────────────────────
_PAYMENT_KEYWORDS   = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "キャッシュレス", "支払い方法"]
_WEEKDAY_KEYWORDS   = ["月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜", "曜日", "週末", "平日"]
_NECESSITY_COMPOUND = ["必要支出", "便利支出", "贅沢支出", "必要度"]
_ADVICE_TRIGGERS    = ["節約", "削減", "見直し", "改善", "減らす", "コツ", "アドバイス"]
_FINANCE_KEYWORDS   = ["家計", "支出", "節約", "費", "お金", "収入", "レシート", "買い物", "購入"]

def keyword_prefilter(question: str) -> str | None:
    """ルールで確信度高く判定できる場合のみインテントを返す。不明は None。"""
    # 1. payment: 支払い方法固有語（偽陽性ほぼゼロ）
    if any(kw in question for kw in _PAYMENT_KEYWORDS):
        return "payment"

    # 2. weekday: 曜日名・週末・平日
    if any(kw in question for kw in _WEEKDAY_KEYWORDS):
        return "weekday"

    # 3. necessity: 複合語のみ（単体の「必要」は対象外）
    if any(kw in question for kw in _NECESSITY_COMPOUND):
        return "necessity"

    # 4. category: カテゴリ名あり かつ アドバイストリガーなし
    has_advice_trigger = any(kw in question for kw in _ADVICE_TRIGGERS)
    if not has_advice_trigger:
        if any(cat in question for cat in ALL_CATEGORIES):
            return "category"

    return None  # LLM に委ねる

def parse_intent_from_json(raw: str) -> str:
    """Swift: QueryIntent.parse(from:) と同等"""
    # cleanResponse 相当
    text = raw
    if "</think>" in text:
        text = text.split("</think>")[-1]
    elif "<think>" in text:
        text = text[:text.find("<think>")]
    for tok in ["<|im_end|>", "<|im_start|>", "</s>"]:
        if tok in text:
            text = text[:text.find(tok)]
    text = text.strip()

    # JSON パース
    match = re.search(r'\{[^}]+\}', text)
    if match:
        try:
            obj = json.loads(match.group())
            intent_str = str(obj.get("intent", "")).lower().strip()
            if intent_str in VALID_INTENTS:
                return intent_str
        except json.JSONDecodeError:
            pass
    return "overview"  # Swift フォールバック

# ─────────────────────────────────────────────────────────────
# モックデータ
# ─────────────────────────────────────────────────────────────
@dataclass
class MockReceipt:
    date_str: str
    category: str
    necessity: str
    payment: str
    total: int
    is_income: bool = False

    @property
    def receipt_date(self):
        return datetime.datetime.strptime(self.date_str, "%Y-%m-%d")

def _r(d, c, n, p, t):
    return MockReceipt(d, c, n, p, t)

MOCK_PATTERNS = {
    "A": [  # 食費・交通の便利支出が多い（現金多め）
        _r("2026-03-05", "食費",         "便利", "現金",             920),
        _r("2026-03-10", "交通・移動費",  "便利", "QRコード決済",     650),
        _r("2026-03-15", "食費",         "必要", "クレジットカード", 3100),
        _r("2026-03-20", "日用品・雑貨費","必要", "現金",            1100),
        _r("2026-03-25", "食費",         "便利", "現金",             870),
        _r("2026-04-01", "食費",         "便利", "現金",             980),
        _r("2026-04-02", "食費",         "便利", "現金",            1250),
        _r("2026-04-03", "交通・移動費",  "便利", "QRコード決済",     850),
        _r("2026-04-04", "食費",         "必要", "クレジットカード", 3200),
        _r("2026-04-05", "日用品・雑貨費","必要", "現金",             780),
        _r("2026-04-08", "食費",         "便利", "現金",            1580),
        _r("2026-04-09", "交通・移動費",  "便利", "QRコード決済",    1200),
        _r("2026-04-10", "食費",         "便利", "現金",             720),
        _r("2026-04-11", "食費",         "必要", "クレジットカード", 2800),
        _r("2026-04-14", "通信費",        "必要", "クレジットカード", 3500),
        _r("2026-04-15", "食費",         "便利", "現金",             980),
        _r("2026-04-16", "交通・移動費",  "便利", "QRコード決済",     650),
        _r("2026-04-17", "サブスク費",   "便利", "クレジットカード", 1500),
        _r("2026-04-20", "食費",         "便利", "現金",            1100),
        _r("2026-04-22", "日用品・雑貨費","必要", "現金",            1200),
        _r("2026-04-25", "食費",         "必要", "クレジットカード", 2500),
        _r("2026-04-28", "交通・移動費",  "便利", "QRコード決済",     780),
        _r("2026-04-29", "食費",         "便利", "現金",             850),
    ],
    "B": [  # 趣味・外食の贅沢支出が多い
        _r("2026-03-01", "食費",         "必要", "クレジットカード", 3100),
        _r("2026-03-10", "趣味・娯楽費", "贅沢", "クレジットカード", 5200),
        _r("2026-03-20", "服・美容費",   "贅沢", "クレジットカード", 7800),
        _r("2026-03-28", "食費",         "贅沢", "クレジットカード", 5500),
        _r("2026-04-01", "食費",         "必要", "クレジットカード", 3500),
        _r("2026-04-02", "趣味・娯楽費", "贅沢", "クレジットカード", 4800),
        _r("2026-04-03", "食費",         "贅沢", "クレジットカード", 6200),
        _r("2026-04-05", "日用品・雑貨費","必要", "現金",             800),
        _r("2026-04-07", "趣味・娯楽費", "贅沢", "クレジットカード", 3200),
        _r("2026-04-09", "食費",         "贅沢", "クレジットカード", 5500),
        _r("2026-04-11", "服・美容費",   "贅沢", "クレジットカード", 8900),
        _r("2026-04-12", "交通・移動費", "必要", "QRコード決済",     550),
        _r("2026-04-14", "通信費",        "必要", "クレジットカード", 3500),
        _r("2026-04-16", "趣味・娯楽費", "贅沢", "クレジットカード", 2700),
        _r("2026-04-18", "食費",         "贅沢", "クレジットカード", 4300),
        _r("2026-04-20", "サブスク費",   "便利", "クレジットカード", 2800),
        _r("2026-04-22", "交際費",        "贅沢", "クレジットカード", 6000),
        _r("2026-04-25", "食費",         "必要", "クレジットカード", 2900),
        _r("2026-04-28", "趣味・娯楽費", "贅沢", "クレジットカード", 3500),
    ],
    "C": [  # バランス型（必要支出中心）
        _r("2026-03-01", "食費",         "必要", "クレジットカード", 3600),
        _r("2026-03-15", "交通・移動費", "必要", "QRコード決済",    1000),
        _r("2026-03-28", "日用品・雑貨費","必要", "QRコード決済",   1400),
        _r("2026-04-01", "食費",         "必要", "クレジットカード", 3800),
        _r("2026-04-03", "交通・移動費", "必要", "QRコード決済",    1200),
        _r("2026-04-05", "食費",         "必要", "クレジットカード", 4200),
        _r("2026-04-07", "日用品・雑貨費","必要", "QRコード決済",   1500),
        _r("2026-04-09", "食費",         "便利", "現金",             980),
        _r("2026-04-10", "通信費",        "必要", "クレジットカード", 3500),
        _r("2026-04-12", "医療・健康費", "必要", "クレジットカード", 1800),
        _r("2026-04-14", "食費",         "必要", "クレジットカード", 3600),
        _r("2026-04-16", "趣味・娯楽費", "贅沢", "クレジットカード", 1500),
        _r("2026-04-18", "交通・移動費", "必要", "QRコード決済",     800),
        _r("2026-04-20", "食費",         "必要", "クレジットカード", 3300),
        _r("2026-04-22", "日用品・雑貨費","必要", "QRコード決済",   1200),
        _r("2026-04-25", "食費",         "便利", "現金",             750),
        _r("2026-04-28", "サブスク費",   "便利", "クレジットカード",  980),
    ],
}

# ─────────────────────────────────────────────────────────────
# テストケース（多様なプロンプト）
# ─────────────────────────────────────────────────────────────
# (質問文, 期待意図, 備考)
TEST_CASES = [
    # ── advice ──────────────────────────────────────────────
    ("節約のアドバイスをして",               "advice",    "サジェスト文言そのまま"),
    ("一番無駄な出費はどこ？",               "advice",    "サジェスト文言そのまま"),
    ("節約のコツを教えて",                   "advice",    "典型: 節約キーワード"),
    ("どこを削減すればいいですか",           "advice",    "削減キーワード"),
    ("貯金を増やしたい",                     "advice",    "「節約」なし"),
    ("お金の使い方を改善したい",             "advice",    "「改善」含む"),
    ("家計を見直したい",                     "advice",    "「見直し」"),
    ("どこを減らせますか",                   "advice",    "「減らす」"),

    # ── overview ────────────────────────────────────────────
    ("支出の全体的な傾向を教えて",           "overview",  "サジェスト文言そのまま"),
    ("全体的な支出状況を教えて",             "overview",  "「全体」"),
    ("家計の概要を見せて",                   "overview",  "「概要」"),
    ("今月どれくらい使いましたか",           "overview",  "「今月」"),
    ("最近の支出傾向を教えて",               "overview",  "「傾向」"),
    ("家計は健全ですか？",                   "overview",  "overview範囲（scoreなし）"),

    # ── category ────────────────────────────────────────────
    ("今月の食費はいくら？",                 "category",  "「食費」"),
    ("交通費について教えて",                 "category",  "「交通費」"),
    ("趣味・娯楽費の詳細を教えて",           "category",  "「詳細」"),
    ("サブスクの費用は？",                   "category",  "カテゴリ名含む"),
    ("外食にいくら使っている？",             "category",  "「外食」"),
    ("日用品への支出を教えて",               "category",  "「日用品」"),
    ("通信費はどれくらいですか",             "category",  "「通信費」"),
    ("美容費を教えて",                       "category",  "「美容費」"),

    # ── trend ───────────────────────────────────────────────
    ("先月の支出はいくらでしたか",           "trend",     "「先月」"),
    ("月ごとの支出の変化を教えて",           "trend",     "「月ごと」「変化」"),
    ("支出の推移を見せて",                   "trend",     "「推移」"),
    ("毎月どのくらい使っていますか",         "trend",     "「毎月」"),
    ("3ヶ月間の支出変化を教えて",           "trend",     "「ヶ月」「変化」"),

    # ── necessity ───────────────────────────────────────────
    ("贅沢支出はどれくらいですか",           "necessity", "「贅沢支出」"),
    ("必要支出の割合は？",                   "necessity", "「必要支出」"),
    ("便利支出について教えて",               "necessity", "「便利支出」"),
    ("必要・便利・贅沢の内訳を教えて",       "necessity", "「必要度」全般"),

    # ── payment ─────────────────────────────────────────────
    ("現金とカードどちらが多い？",           "payment",   "「現金」「カード」"),
    ("支払い方法の内訳を教えて",             "payment",   "「支払い方法」"),
    ("クレジットカードはどのくらい使った？", "payment",   "「クレジットカード」"),
    ("QRコード決済の割合は？",               "payment",   "「QRコード」"),
    ("電子マネーを使っていますか？",         "payment",   "「電子マネー」"),
    ("キャッシュレス比率を教えて",           "payment",   "「キャッシュレス」"),

    # ── weekday ─────────────────────────────────────────────
    ("何曜日に一番お金を使っていますか",     "weekday",   "「曜日」"),
    ("週末に使いすぎていますか？",           "weekday",   "「週末」"),
    ("支出が多い時期はいつですか",           "weekday",   "「時期」"),
    ("土曜日の支出を教えて",                 "weekday",   "「土曜日」→曜日名"),

    # ── help → helpインテント廃止、overviewへ落ちることを期待 ───
    ("何ができますか？",                     "overview",  "help廃止→overview期待"),
    ("使い方を教えて",                       "overview",  "help廃止→overview期待"),
    ("このAIの機能を教えてください",         "overview",  "help廃止→overview期待"),
    ("どんな質問に答えられますか",           "overview",  "help廃止→overview期待"),

    # ── offtopic ────────────────────────────────────────────
    ("今日の天気は？",                       "offtopic",  "完全スコープ外"),
    ("おすすめのレシピを教えて",             "offtopic",  "家計と無関係"),
    ("株の買い方を教えて",                   "offtopic",  "投資 → offtopic"),
    ("ダイエットの方法を教えて",             "offtopic",  "健康 → offtopic"),
]

# ─────────────────────────────────────────────────────────────
# AnalysisContext 構築（AdviceLLMService.buildAnalysisContext の Python 移植）
# ─────────────────────────────────────────────────────────────
ALL_CATEGORIES = [
    "食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費",
    "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費",
    "サブスク費", "勉強費", "その他",
]
WEEKDAY_NAMES = ["", "日", "月", "火", "水", "木", "金", "土"]  # Swift: index=1 は日曜

CONVENIENCE_TIPS = {
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
    "その他": "具体的には、使途不明金（小規模な便利支出）を可視化するため、少額決済こそ記録を意識し、財布の紐が緩む「ついでの瞬間」を特定してください。",
}

LUXURY_TIPS = {
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
    "その他": "具体的には、自分への過度なご褒美を控え、支出が本当に人生の質を高めているか再確認する習慣を持ってください。",
}


def _score_message(score: int, necessity_ratio: float, target_ratio: float = 62.5) -> str:
    if score >= 90:
        return "節約疲れもなく、浪費の罪悪感もない。お金が最適に使われた完璧に近い状態です。"
    if score >= 70:
        return "合格点です。この範囲を維持できていれば、お金のストレスは最小限です。"
    if score >= 40:
        if necessity_ratio > target_ratio:
            return "必要支出の割合が高めです。固定費などの必要な支出を見直すか、少しの贅沢を取り入れて、生活に心のゆとりを持たせることも検討してみてください。"
        return "必要支出の割合が低く、便利や贅沢への支出が目立ちます。自炊を取り入れたり、贅沢を少し控えることで、より健全な家計に近づけることができます。"
    return "支出のコントロール権を「自分の欲望（便利・贅沢）」に奪われつつあります。家計防衛の観点から赤信号です。"


def _trend_message(monthly_totals: list, avg: int) -> str:
    if len(monthly_totals) < 2:
        return "まだデータが1ヶ月分のみのため、今後の推移に注目していきましょう。"
    latest = monthly_totals[-1]
    previous = monthly_totals[-2]
    if latest < previous and latest < avg:
        return "直近は前月比・平均比ともに減少しており、良いペースで支出をコントロールできています。"
    if latest > previous and latest > avg:
        return "直近は前月比・平均比ともに増加傾向にあり、支出が膨らみやすい時期かもしれません。引き締めを意識しましょう。"
    if latest > previous:
        return "平均よりは抑えられていますが、前月よりは増加しています。微増傾向にあるため注意してください。"
    return "前月よりは減少していますが、平均よりは高い水準です。引き続き、平均ラインを目指して調整していきましょう。"


def build_analysis_context(receipts):
    """Swift: AdviceLLMService.buildAnalysisContext の Python 移植（現在実装と完全一致）"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses  # 期間フィルタは省略（スクリプト内ではモック全件使用）
    record_count = len(target)
    if record_count == 0:
        return None

    period_label = "直近3ヶ月"  # モックデータ用ラベル

    total_amount = sum(r.total for r in target)

    # 必要度グループ
    nec_groups = {}
    for r in target:
        nec_groups.setdefault(r.necessity, []).append(r)

    # 支払いグループ
    pay_groups = {}
    for r in target:
        pay_groups.setdefault(r.payment, []).append(r)

    # 現金比率
    cash_total = sum(r.total for r in pay_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount else 0

    # スコア計算
    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in nec_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount else 0

    # 便利・贅沢合計
    convenience_total = sum(r.total for r in nec_groups.get("便利", []))
    luxury_total = sum(r.total for r in nec_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount else 0

    # 節約余地
    saving_potentials = []
    if conv_ratio > 30 and nec_groups.get("便利"):
        cat_totals = {}
        for r in nec_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips = "".join(CONVENIENCE_TIPS.get(k, "日々の「なんとなく」の支出を意識的に減らす工夫をしてみましょう。") for k, _ in sorted_cats)
        saving_potentials.append(
            f"便利支出であり、{convenience_total}円（総支出の{int(conv_ratio)}%）を占めています。"
            f"便利支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips}"
        )
    if lux_ratio > 30 and nec_groups.get("贅沢"):
        cat_totals = {}
        for r in nec_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips = "".join(LUXURY_TIPS.get(k, "その支出が本当に価格に見合う価値を提供しているか、再確認してみましょう。") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出であり、{luxury_total}円（総支出の{int(lux_ratio)}%）を占めています。"
            f"贅沢支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips}"
        )
    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "特にありません。大きな節約余地がないことをユーザーに明示してください。"
    )

    # 月別グループ
    monthly_groups = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly_total = int(sum(monthly_totals) / len(monthly_totals)) if monthly_totals else 0

    # 支払い方法メッセージ
    payment_method_message = (
        f"現金支払いが{cash_total}円（総支出の{cash_pct}%）を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
        if cash_pct >= 30
        else "キャッシュレス決済を主体に、ポイント還元などを活用して上手に買い物ができています。"
    )

    # 必要度別内訳
    necessity_lines = "\n".join(
        f"   - {nec}：{sum(r.total for r in nec_groups.get(nec, []))}円"
        f"（総支出の{int(sum(r.total for r in nec_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    # カテゴリ別内訳
    cat_groups = {}
    for r in target:
        cat_groups.setdefault(r.category, []).append(r)
    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = cat_groups.get(cat, [])
        ct = sum(r.total for r in items)
        cp = int(ct / total_amount * 100) if total_amount else 0
        nec_in_cat = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_d = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                lp = int(v / ct * 100) if ct else 0
                nec_d.append(f"{cat}の{nec}支出は{v}円で{cat}の{lp}%")
            else:
                nec_d.append(f"{cat}の{nec}支出はありません")
        if ct > 0:
            cat_lines.append(f"   - {cat}：{ct}円（総支出の{cp}%, {'、'.join(nec_d)}）")
        else:
            cat_lines.append(f"   - {cat}：支出なし（0円, {'、'.join(nec_d)}）")
    category_lines = "\n".join(cat_lines)

    # 支払い方法別内訳
    all_payments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
    payment_lines = "\n".join(
        f"   - {m}：{sum(r.total for r in pay_groups.get(m, []))}円"
        f"（総支出の{int(sum(r.total for r in pay_groups.get(m, []))/total_amount*100) if total_amount else 0}%）"
        for m in all_payments
    )

    # 曜日グループ（Swift: calendar.component(.weekday) = 1:日〜7:土）
    weekday_groups = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1  # isoweekday 1=Mon→2, 7=Sun→1
        weekday_groups.setdefault(wd, []).append(r)

    biased_weekdays = []
    wd_lines = []
    for wd in range(1, 8):
        amt = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amt / total_amount * 100) if total_amount else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
        wd_lines.append(f"   - {WEEKDAY_NAMES[wd]}曜日：{amt}円（総支出の{pct}%）")
    weekday_trend_message = (
        "曜日による支出の偏りは特にありません。" if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に支出が集中しています。"
    )
    weekday_lines = "\n".join(wd_lines)

    # 月別実数値
    monthly_lines = "\n".join(
        f"   - {k}: {sum(r.total for r in monthly_groups[k])}円"
        f"（全体の{int(sum(r.total for r in monthly_groups[k])/total_amount*100) if total_amount else 0}%）"
        for k in sorted_months
    )

    # 時系列×必要度クロス集計
    trend_by_necessity_parts = []
    for k in sorted_months:
        month_receipts = monthly_groups[k]
        month_total = sum(r.total for r in month_receipts)
        nec_g = {}
        for r in month_receipts:
            nec_g.setdefault(r.necessity, []).append(r)
        parts = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_g.get(nec, []))
            pct = int(v / month_total * 100) if month_total else 0
            parts.append(f"{nec} {v}円({pct}%)")
        trend_by_necessity_parts.append(f"   - {k}（{month_total}円）: {'、'.join(parts)}")
    trend_by_necessity_lines = "\n".join(trend_by_necessity_parts)

    # 時系列×カテゴリクロス集計
    trend_by_category_parts = []
    for k in sorted_months:
        month_receipts = monthly_groups[k]
        month_total = sum(r.total for r in month_receipts)
        cat_g = {}
        for r in month_receipts:
            cat_g.setdefault(r.category, []).append(r)
        parts = []
        for cat in ALL_CATEGORIES:
            v = sum(r.total for r in cat_g.get(cat, []))
            if v > 0:
                pct = int(v / month_total * 100) if month_total else 0
                parts.append(f"{cat} {v}円({pct}%)")
        trend_by_category_parts.append(
            f"   - {k}（{month_total}円）: {'、'.join(parts) if parts else 'データなし'}"
        )
    trend_by_category_lines = "\n".join(trend_by_category_parts)

    # 曜日×必要度クロス集計
    weekday_by_necessity_parts = []
    for wd in range(1, 8):
        wd_receipts = weekday_groups.get(wd, [])
        wd_total = sum(r.total for r in wd_receipts)
        nec_g = {}
        for r in wd_receipts:
            nec_g.setdefault(r.necessity, []).append(r)
        parts = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_g.get(nec, []))
            pct = int(v / wd_total * 100) if wd_total else 0
            parts.append(f"{nec} {v}円({pct}%)")
        weekday_by_necessity_parts.append(f"   - {WEEKDAY_NAMES[wd]}曜日（{wd_total}円）: {'、'.join(parts)}")
    weekday_by_necessity_lines = "\n".join(weekday_by_necessity_parts)

    # 曜日×カテゴリクロス集計
    weekday_by_category_parts = []
    for wd in range(1, 8):
        wd_receipts = weekday_groups.get(wd, [])
        wd_total = sum(r.total for r in wd_receipts)
        cat_g = {}
        for r in wd_receipts:
            cat_g.setdefault(r.category, []).append(r)
        parts = []
        for cat in ALL_CATEGORIES:
            v = sum(r.total for r in cat_g.get(cat, []))
            if v > 0:
                pct = int(v / wd_total * 100) if wd_total else 0
                parts.append(f"{cat} {v}円({pct}%)")
        weekday_by_category_parts.append(
            f"   - {WEEKDAY_NAMES[wd]}曜日（{wd_total}円）: {'、'.join(parts) if parts else '支出なし'}"
        )
    weekday_by_category_lines = "\n".join(weekday_by_category_parts)

    # 支出上位カテゴリ Top3
    cat_totals_all = [(cat, sum(r.total for r in cat_groups.get(cat, []))) for cat in ALL_CATEGORIES]
    top_category_lines = "\n".join(
        f"   - {cat}：{amt}円（総支出の{int(amt/total_amount*100) if total_amount else 0}%）"
        for cat, amt in sorted(cat_totals_all, key=lambda x: -x[1])[:3] if amt > 0
    )

    # 必要度×カテゴリクロス集計
    necessity_by_category_parts = []
    for nec in ["必要", "便利", "贅沢"]:
        nec_items = nec_groups.get(nec, [])
        nec_total = sum(r.total for r in nec_items)
        nec_pct = int(nec_total / total_amount * 100) if total_amount else 0
        nec_cat_g = {}
        for r in nec_items:
            nec_cat_g.setdefault(r.category, []).append(r)
        top_cats = sorted(
            [(cat, sum(r.total for r in nec_cat_g.get(cat, []))) for cat in ALL_CATEGORIES if sum(r.total for r in nec_cat_g.get(cat, [])) > 0],
            key=lambda x: -x[1]
        )[:3]
        top_str = "、".join(
            f"{cat} {amt}円({int(amt/nec_total*100) if nec_total else 0}%)"
            for cat, amt in top_cats
        ) if top_cats else "支出なし"
        necessity_by_category_parts.append(
            f"   - {nec}（{nec_total}円, 総支出の{nec_pct}%）: 上位カテゴリ → {top_str}"
        )
    necessity_by_category_lines = "\n".join(necessity_by_category_parts)

    return {
        "period_label": period_label,
        "total_amount": total_amount,
        "record_count": record_count,
        "avg_monthly_total": avg_monthly_total,
        "spending_score": spending_score,
        "necessity_ratio": necessity_ratio,
        "score_message": _score_message(spending_score, necessity_ratio),
        "saving_potential_message": saving_potential_message,
        "payment_method_message": payment_method_message,
        "spending_trend_message": _trend_message(monthly_totals, avg_monthly_total),
        "weekday_trend_message": weekday_trend_message,
        "necessity_lines": necessity_lines,
        "category_lines": category_lines,
        "payment_lines": payment_lines,
        "weekday_lines": weekday_lines,
        "monthly_lines": monthly_lines,
        "trend_by_necessity_lines": trend_by_necessity_lines,
        "trend_by_category_lines": trend_by_category_lines,
        "weekday_by_necessity_lines": weekday_by_necessity_lines,
        "weekday_by_category_lines": weekday_by_category_lines,
        "top_category_lines": top_category_lines,
        "necessity_by_category_lines": necessity_by_category_lines,
    }


# ─────────────────────────────────────────────────────────────
# Section Builders（Swift: sectionXxx の Python 移植）
# ─────────────────────────────────────────────────────────────

def section_summary(ctx) -> str:
    return (
        f"## 支出サマリー（{ctx['period_label']}）\n"
        f"・合計支出：{ctx['total_amount']}円（{ctx['record_count']}件）\n"
        f"・月平均支出：{ctx['avg_monthly_total']}円\n"
        f"・支出増減傾向：{ctx['spending_trend_message']}\n\n"
        f"【支出健全度スコア】\n"
        f"・スコア：{ctx['spending_score']}点\n"
        f"・{ctx['score_message']}\n\n"
        f"【必要度別内訳】\n{ctx['necessity_lines']}\n\n"
        f"【支出上位カテゴリ Top3】\n{ctx['top_category_lines']}"
    )

def section_saving(ctx) -> str:
    return (
        f"## 節約余地アドバイス\n"
        f"以下の節約アドバイスをユーザーにそのままお伝えください：\n"
        f"{ctx['saving_potential_message']}"
    )

def section_payment(ctx) -> str:
    return (
        f"## 支払い方法の分析\n"
        f"{ctx['payment_method_message']}\n\n"
        f"【支払い方法別内訳】\n{ctx['payment_lines']}"
    )

def section_trend(ctx) -> str:
    return (
        f"## 支出の推移\n"
        f"{ctx['spending_trend_message']}\n"
        f"月平均支出：{ctx['avg_monthly_total']}円\n\n"
        f"【月別支出】\n{ctx['monthly_lines']}\n\n"
        f"【月別×必要度クロス集計】\n{ctx['trend_by_necessity_lines']}\n\n"
        f"【月別×カテゴリクロス集計】\n{ctx['trend_by_category_lines']}"
    )

def section_weekday(ctx) -> str:
    return (
        f"## 曜日別支出\n"
        f"{ctx['weekday_trend_message']}\n\n"
        f"【曜日別内訳】\n{ctx['weekday_lines']}\n\n"
        f"【曜日×必要度クロス集計】\n{ctx['weekday_by_necessity_lines']}\n\n"
        f"【曜日×カテゴリクロス集計】\n{ctx['weekday_by_category_lines']}"
    )

def section_necessity(ctx) -> str:
    return (
        f"## 必要度別支出\n"
        f"【必要度別内訳】\n{ctx['necessity_lines']}\n\n"
        f"【必要度×カテゴリクロス集計】\n{ctx['necessity_by_category_lines']}\n\n"
        f"【月別×必要度クロス集計（必要度×時系列）】\n{ctx['trend_by_necessity_lines']}\n\n"
        f"【曜日別×必要度クロス集計（必要度×曜日）】\n{ctx['weekday_by_necessity_lines']}"
    )

def section_category(ctx) -> str:
    return (
        f"## カテゴリ別支出\n"
        f"【カテゴリ別内訳（カテゴリ×必要度）】\n{ctx['category_lines']}\n\n"
        f"【月別×カテゴリクロス集計（カテゴリ×時系列）】\n{ctx['trend_by_category_lines']}\n\n"
        f"【曜日別×カテゴリクロス集計（カテゴリ×曜日）】\n{ctx['weekday_by_category_lines']}"
    )

SECTION_BUILDERS = {
    "summary":   section_summary,
    "saving":    section_saving,
    "payment":   section_payment,
    "trend":     section_trend,
    "weekday":   section_weekday,
    "necessity": section_necessity,
    "category":  section_category,
}

# offtopic / help プロンプト（Swift buildSystemPrompt の特殊ケース）
STAGE2_PERSONA = "あなたはAI家計ナビの節約AIです。登録されたレシートをもとに家計・支出に関する質問に答えます。"

OFFTOPIC_PROMPT = f"""{STAGE2_PERSONA}
節約アドバイス、支出全体のサマリー、カテゴリ別・月別・曜日別の支出集計、支払い方法の確認ができます。

# 命令文：
ユーザーの質問を確認し、以下の方針で回答してください。
- このAIの機能・使い方を聞いている場合（例: 何ができる？、使い方は？、どんな質問に答えられる？）は、上記の機能を簡潔に説明してください。
- 家計・支出と全く無関係な質問（例: 天気、料理、ダイエット、ニュース）は、回答できないことを丁寧に伝え、家計や節約についての質問を促してください。

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は150字以内で。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。"""

NO_DATA_PROMPT = f"""{STAGE2_PERSONA}

# 命令文：
ユーザーはまだ支出データを一件も登録していません。支出レポートは存在しません。
支出データが登録されていないため、支出に基づいたアドバイスや分析はできないことをユーザーに伝えてください。
レシートを登録するよう、丁寧に促してください。

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は200字以内で簡潔に。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。"""

COMMON_FOOTER = """
# 回答の基本原則（最優先）：
1. **数値の透明性**: 質問に直接関係する数値のみを引用し、金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
2. **簡潔な回答**: 回答は300字以内で簡潔に。
3. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
4. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。"""


def build_system_prompt(receipts, intent: str) -> str:
    """Swift: AdviceLLMService.buildSystemPrompt の Python 移植"""
    if intent == "offtopic":
        return OFFTOPIC_PROMPT

    sections = SECTIONS_MAP[intent]
    ctx = build_analysis_context(receipts)
    if ctx is None:
        return NO_DATA_PROMPT

    parts = [
        f"{STAGE2_PERSONA}\n\n"
        f"# 命令文：\n"
        f"以下のユーザーの支出レポートから情報を抜き出すことで、ユーザーの質問に回答してください。\n\n"
        f"# 支出レポート（{ctx['period_label']}・合計{ctx['total_amount']}円・{ctx['record_count']}件）："
    ]
    for s in sections:
        if s in SECTION_BUILDERS:
            parts.append(SECTION_BUILDERS[s](ctx))
    parts.append(COMMON_FOOTER)
    return "\n\n".join(parts)


def clean_response(text: str) -> str:
    """Swift: cleanResponse と同等"""
    if "</think>" in text:
        text = text.split("</think>")[-1]
    elif "<think>" in text:
        text = text[:text.find("<think>")]
    for tok in ["<|im_end|>", "<|im_start|>", "</s>"]:
        if tok in text:
            text = text[:text.find(tok)]
    return text.strip()


# ─────────────────────────────────────────────────────────────
# モード: --dry-run
# ─────────────────────────────────────────────────────────────
def run_dry_run(pattern_name: str):
    receipts = MOCK_PATTERNS[pattern_name]
    ctx = build_analysis_context(receipts)

    print("=" * 100)
    print(f"【Dry-Run】セクション構成＆システムプロンプト確認（パターン {pattern_name}）")
    print(f"  合計{ctx['total_amount']}円・{ctx['record_count']}件・スコア{ctx['spending_score']}点")
    print("=" * 100)
    print()
    print(f"{'#':<3} {'質問文':<32} {'期待意図':<12} {'sections':<30} {'プロンプト長'}")
    print("-" * 100)

    for i, (q, expected, note) in enumerate(TEST_CASES, 1):
        sections = SECTIONS_MAP[expected]
        sys_prompt = build_system_prompt(receipts, expected)
        sec_str = ", ".join(sections) if sections else "(固定文言)"
        q_disp = q[:30] + ".." if len(q) > 30 else q
        print(f"{i:<3} {q_disp:<32} {expected:<12} {sec_str:<30} {len(sys_prompt)}文字")

    print()
    print("【意図別サマリー】")
    print(f"{'意図':<12} {'件数':<6} {'sections':<40} {'平均プロンプト長'}")
    print("-" * 80)
    from collections import Counter
    intent_counts = Counter(e for _, e, _ in TEST_CASES)
    for intent in ["advice", "overview", "category", "trend", "necessity", "payment", "weekday", "offtopic"]:
        cnt = intent_counts[intent]
        sections = SECTIONS_MAP[intent]
        sec_str = ", ".join(sections) if sections else "(固定文言)"
        sys_prompt = build_system_prompt(receipts, intent)
        print(f"{intent:<12} {cnt:<6} {sec_str:<40} {len(sys_prompt)}文字")


# ─────────────────────────────────────────────────────────────
# モード: --stage1
# ─────────────────────────────────────────────────────────────
def run_stage1(model, tokenizer):
    from mlx_lm import generate as mlx_generate
    from collections import Counter

    total = len(TEST_CASES)
    results = []

    print("=" * 120)
    print("【Stage 1】LLM意図分類精度テスト + ハイブリッド比較")
    print("=" * 120)
    print(f"{'#':<3} {'質問文':<32} {'期待':<12} {'ルール':<12} {'LLM':<12} {'ハイブリッド':<14} 備考")
    print("-" * 120)

    for i, (q, expected, note) in enumerate(TEST_CASES, 1):
        # キーワード先読み
        rule_intent = keyword_prefilter(q)

        # LLM（常に実行して比較できるようにする）
        prompt_text = build_stage1_prompt(q)
        messages = [{"role": "user", "content": prompt_text}]
        formatted = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
        )
        raw = mlx_generate(model, tokenizer, prompt=formatted, max_tokens=50, verbose=False)
        llm_intent = parse_intent_from_json(raw)

        # ハイブリッド: ルールが発火したらルール優先、なければLLM
        hybrid_intent = rule_intent if rule_intent is not None else llm_intent
        rule_disp = rule_intent if rule_intent is not None else "—"

        hybrid_ok = hybrid_intent == expected
        mark = "✅" if hybrid_ok else "❌"
        llm_mark = "✅" if llm_intent == expected else "❌"

        q_disp = q[:30] + ".." if len(q) > 30 else q
        print(f"{i:<3} {q_disp:<32} {expected:<12} {rule_disp:<12} {llm_intent+llm_mark:<14} {hybrid_intent+mark:<16} {note}")
        results.append((q, expected, rule_intent, llm_intent, hybrid_intent, note))

    print("-" * 120)

    total_by_intent = Counter(e for _, e, *_ in TEST_CASES)
    llm_correct   = Counter(e for _, e, _, li, _, _ in results if li == e)
    hybrid_correct = Counter(e for _, e, _, _, hi, _ in results if hi == e)

    llm_total   = sum(1 for _, e, _, li, _, _ in results if li == e)
    hybrid_total = sum(1 for _, e, _, _, hi, _ in results if hi == e)

    rule_fired = sum(1 for _, _, ri, _, _, _ in results if ri is not None)
    rule_correct = sum(1 for _, e, ri, _, _, _ in results if ri is not None and ri == e)

    print(f"\n{'─'*60}")
    print(f"  LLM単体     : {llm_total}/{total} 正解 ({llm_total/total*100:.1f}%)")
    print(f"  ルール単体   : {rule_correct}/{rule_fired} 正解 ({rule_correct/rule_fired*100:.1f}%) ← ルールが発火した{rule_fired}問中")
    print(f"  ハイブリッド : {hybrid_total}/{total} 正解 ({hybrid_total/total*100:.1f}%)")
    print(f"{'─'*60}")

    all_intents = ["advice", "overview", "category", "trend", "necessity", "payment", "weekday", "help", "offtopic"]

    print("\n【意図別精度】")
    print(f"  {'意図':<12} {'LLM':>6}  {'Hybrid':>6}  {'差分':>5}  ルール発火")
    for intent in all_intents:
        t = total_by_intent[intent]
        lc = llm_correct[intent]
        hc = hybrid_correct[intent]
        fired = sum(1 for _, e, ri, _, _, _ in results if e == intent and ri is not None)
        diff = hc - lc
        diff_str = f"+{diff}" if diff > 0 else str(diff) if diff < 0 else "  0"
        lbar = "█" * int(lc/t*10) + "░" * (10 - int(lc/t*10)) if t else "░"*10
        if t == 0:
            continue
        print(f"  {intent:<12} {lc}/{t} {lbar} {lc/t*100:>4.0f}%  →  {hc}/{t} {hc/t*100:>4.0f}%  ({diff_str})  fired={fired}/{t}")

    print("\n【誤分類の詳細（ハイブリッド）】")
    misses = [(q, e, ri, li, hi) for q, e, ri, li, hi, _ in results if hi != e]
    if misses:
        for q, e, ri, li, hi in misses:
            src = f"ルール({ri})" if ri is not None else f"LLM({li})"
            print(f"  ❌ \"{q}\"")
            print(f"     期待={e} → {src} → hybrid={hi}")
    else:
        print("  なし（全問正解）")

    print("\n【ルール発火一覧】")
    print(f"  {'#':<3} {'質問文':<32} {'ルール判定':<12} {'正解?'}")
    for i, (q, e, ri, li, hi, _) in enumerate(results, 1):
        if ri is not None:
            q_disp = q[:30] + ".." if len(q) > 30 else q
            mark = "✅" if ri == e else "❌"
            print(f"  {i:<3} {q_disp:<32} {ri:<12} {mark}")


# ─────────────────────────────────────────────────────────────
# モード: --full（Stage 1 + Stage 2）
# ─────────────────────────────────────────────────────────────
def run_full(model, tokenizer, receipts, pattern_name: str, question_filter=None, max_tokens: int = 1200, override_cases=None):
    from mlx_lm import generate as mlx_generate

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    results_dir = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(results_dir, exist_ok=True)
    out_path = os.path.join(results_dir, f"{timestamp}_current_pattern{pattern_name}.txt")

    cases = override_cases if override_cases else TEST_CASES
    if question_filter:
        cases = [(q, e, n) for q, e, n in cases if q == question_filter]
        if not cases:
            print(f"WARNING: '{question_filter}' に一致する質問がありません")
            cases = override_cases if override_cases else TEST_CASES

    print("=" * 100)
    print(f"【Full Pipeline】パターン={pattern_name}  {len(cases)}問  max_tokens={max_tokens}")
    print("=" * 100)

    ctx = build_analysis_context(receipts)
    if ctx:
        print(f"  データ: 合計{ctx['total_amount']}円・{ctx['record_count']}件・スコア{ctx['spending_score']}点")
    print()

    summary_rows = []

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(f"=== 節約AI 完全パイプラインテスト / パターン: {pattern_name} ===\n")
        f.write(f"実行日時: {timestamp}\n\n")

        for i, (q, expected, note) in enumerate(cases, 1):
            print(f"[{i:02d}/{len(cases)}] Q: {q}")
            f.write(f"{'='*70}\n")
            f.write(f"[{i}] Q: {q}\n期待意図: {expected}  備考: {note}\n\n")

            # ── Stage 1: 意図分類 ──
            stage1_prompt = build_stage1_prompt(q)
            s1_messages = [{"role": "user", "content": stage1_prompt}]
            s1_formatted = tokenizer.apply_chat_template(
                s1_messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
            )
            s1_raw = mlx_generate(model, tokenizer, prompt=s1_formatted, max_tokens=50, verbose=False)
            intent = parse_intent_from_json(s1_raw)
            sections = SECTIONS_MAP[intent]
            intent_ok = intent == expected

            print(f"  Stage1: {intent} {'✅' if intent_ok else f'❌(期待:{expected})'}")
            f.write(f"--- Stage 1 ---\n")
            f.write(f"LLM生テキスト: \"{s1_raw.strip()[:80]}\"\n")
            f.write(f"intent: {intent} {'✅' if intent_ok else f'❌(期待:{expected})'}\n")
            f.write(f"sections: {sections}\n\n")

            # ── Stage 2: 回答生成 ──
            system_prompt = build_system_prompt(receipts, intent)
            s2_messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": f"/no_think {q}"},  # Swift: buildConversationMessages
            ]
            s2_formatted = tokenizer.apply_chat_template(
                s2_messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
            )
            s2_raw = mlx_generate(model, tokenizer, prompt=s2_formatted, max_tokens=max_tokens, verbose=False)
            ans = clean_response(s2_raw)

            # ContentFilter チェック（Swift: blocked_keyword チェック）
            hit = blocked_keyword(ans)
            if hit:
                ans = "この回答には投資に関する情報が含まれていたため、表示できませんでした。節約や支出管理についての質問をお試しください。"
                print(f"  🚫 コンテンツフィルター発動: 「{hit}」")

            print(f"  Stage2: {ans[:80]}{'...' if len(ans)>80 else ''}")
            f.write(f"--- Stage 2 ---\n")
            f.write(f"システムプロンプト({len(system_prompt)}文字) sections={sections}\n\n")
            f.write(f"最終回答:\n{ans}\n\n")

            # 品質チェック
            quality_flags = []
            if not intent_ok:
                quality_flags.append(f"⚠ 意図ミス({expected}→{intent})")
            if not sections:
                quality_flags.append("⚠ 固定文言")
            if len(ans) < 30:
                quality_flags.append("⚠ 回答短すぎ")
            if len(ans) > 600:
                quality_flags.append("⚠ 300字超過")
            if hit:
                quality_flags.append(f"⚠ フィルター({hit})")
            flag_str = " / ".join(quality_flags) if quality_flags else "OK"

            if quality_flags:
                f.write(f"品質フラグ: {flag_str}\n")
            f.write("\n")

            # サマリー用
            summary_rows.append({
                "no": i,
                "question": q,
                "expected": expected,
                "actual_intent": intent,
                "intent_ok": intent_ok,
                "sections": sections,
                "answer": ans,
                "ans_len": len(ans),
                "flag": flag_str,
            })
            print()

    # ─ 結果テーブル表示 ─
    print("\n" + "=" * 120)
    print("【テスト結果テーブル】")
    print("=" * 120)
    print(f"{'#':<3} {'質問文':<30} {'期待':<12} {'実際':<12} {'分類':<4} {'回答(先頭60字)':<62} {'フラグ'}")
    print("-" * 120)
    for row in summary_rows:
        q_d = row["question"][:28] + ".." if len(row["question"]) > 28 else row["question"]
        ans_d = row["answer"][:60] + "..." if len(row["answer"]) > 60 else row["answer"]
        mark = "✅" if row["intent_ok"] else "❌"
        print(f"{row['no']:<3} {q_d:<30} {row['expected']:<12} {row['actual_intent']:<12} {mark:<4} {ans_d:<62} {row['flag']}")

    intent_ok_count = sum(1 for r in summary_rows if r["intent_ok"])
    print("-" * 120)
    print(f"意図分類精度: {intent_ok_count}/{len(summary_rows)} ({intent_ok_count/len(summary_rows)*100:.1f}%)")
    print(f"結果ファイル: {out_path}")


# ─────────────────────────────────────────────────────────────
# エントリポイント
# ─────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="節約AI (AdviceLLMService.swift) 忠実再現テスト")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="LLM不使用: セクション構成・プロンプト長確認")
    mode.add_argument("--stage1",  action="store_true", help="Stage 1: LLM分類精度テスト")
    mode.add_argument("--full",    action="store_true", help="Stage 1+2: 完全パイプライン")
    parser.add_argument("--model",      default="mlx-community/Qwen3-1.7B-4bit")
    parser.add_argument("--pattern",    default="A", choices=["A", "B", "C"])
    parser.add_argument("--question",   default=None, help="特定の質問のみ実行（--full 時）")
    parser.add_argument("--max-tokens", type=int, default=1200)
    parser.add_argument("--quick",      action="store_true", help="各意図から代表1問のみ（--full 時）")
    args = parser.parse_args()

    if args.dry_run:
        run_dry_run(args.pattern)
        return

    try:
        from mlx_lm import load
    except ImportError:
        print("ERROR: mlx_lm がインストールされていません")
        sys.exit(1)

    print(f"モデルをロード中: {args.model}")
    model, tokenizer = load(args.model)
    print("ロード完了\n")

    if args.stage1:
        run_stage1(model, tokenizer)
    elif args.full:
        receipts = MOCK_PATTERNS[args.pattern]
        q_filter = args.question
        if args.quick and not q_filter:
            # 各意図から代表1問を選ぶ（テーブル内の最初の質問）
            seen = set()
            quick_cases = []
            for q, e, n in TEST_CASES:
                if e not in seen:
                    quick_cases.append((q, e, n))
                    seen.add(e)
            run_full(model, tokenizer, receipts, args.pattern, q_filter, args.max_tokens, override_cases=quick_cases)
        else:
            run_full(model, tokenizer, receipts, args.pattern, q_filter, args.max_tokens)


if __name__ == "__main__":
    main()
