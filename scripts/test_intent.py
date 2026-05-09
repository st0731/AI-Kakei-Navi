"""
test_intent.py — 現在の AdviceLLMService.swift 2ステージパイプラインのテスト

現在のSwift実装を忠実に再現:
  Stage 1: LLMによる意図分類 (classifyIntent / maxTokens=20)
  Stage 2: sections に応じたシステムプロンプト構築 → 回答生成 (maxTokens=1200)

3モード:
  --dry-run   : LLM不使用。キーワードマッチング（Swift フォールバック）の精度検証のみ
  --stage1    : Stage 1のみ。LLMの分類精度を全テストケースで計測
  --full      : Stage 1 + Stage 2 の完全パイプライン実行

Usage:
  python test_intent.py --dry-run
  python test_intent.py --stage1 --model mlx-community/Qwen3-1.7B-4bit
  python test_intent.py --full   --model mlx-community/Qwen3-1.7B-4bit --pattern A
  python test_intent.py --full   --model mlx-community/Qwen3-1.7B-4bit --question "食費はどのくらい?"
  python test_intent.py --dry-run --print-sections  # 各意図のセクション内容も表示
"""

import argparse
import datetime
import os
import sys
from dataclasses import dataclass

# ─────────────────────────────────────────────────────────────
# 意図分類（QueryIntent）
# ─────────────────────────────────────────────────────────────

VALID_INTENTS = {"advice", "overview", "category", "payment", "score", "weekday", "help", "other"}

SECTIONS_MAP = {
    "advice":   ["summary", "saving"],
    "overview": ["summary", "trend", "necessity"],
    "category": ["category", "necessity", "summary"],
    "payment":  ["payment", "summary"],
    "score":    ["summary", "necessity"],
    "weekday":  ["weekday", "trend", "summary"],
    "help":     [],
    "other":    ["summary", "saving", "payment", "trend", "weekday", "necessity", "category"],
}

# Stage 1 分類プロンプト（Swift の classifyIntent と同じ）
STAGE1_PROMPT_TEMPLATE = """/no_think
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

Question: {question}
Answer (one English word only):"""


def parse_intent_keyword(text: str) -> str:
    """Swift の QueryIntent.parse(from:) と同等のキーワードマッチング"""
    first_word = text.strip().split()[0].lower() if text.strip() else ""
    if first_word in VALID_INTENTS:
        return first_word
    # 競合を避けるため weekday → score → advice → overview の順でチェック
    if any(kw in text for kw in ["曜日", "週末", "時期"]):
        return "weekday"
    if any(kw in text for kw in ["スコア", "評価", "健全", "点数", "大丈夫", "使いすぎ", "しすぎ"]):
        return "score"
    if any(kw in text for kw in ["節約", "アドバイス", "削減", "無駄", "貯金", "減らす", "減らせ", "改善"]):
        return "advice"
    if any(kw in text for kw in ["全体", "推移", "概要", "傾向", "今月", "先月", "毎月"]):
        return "overview"
    if any(kw in text for kw in ["食費", "交通", "カテゴリ", "詳細", "外食", "サブスク", "コンビニ", "日用品", "趣味", "娯楽"]):
        return "category"
    if any(kw in text for kw in ["支払", "現金", "カード", "決済", "電子マネー", "キャッシュレス"]):
        return "payment"
    if any(kw in text for kw in ["機能", "使い方", "できる", "できます", "答えられ"]):
        return "help"
    return "other"


def parse_intent_from_llm_output(raw: str) -> str:
    """LLM の生テキストから意図を抽出（clean後にparse）"""
    # <think>除去
    if "</think>" in raw:
        raw = raw.split("</think>")[-1]
    elif "<think>" in raw:
        raw = raw[:raw.find("<think>")]
    for tok in ["<|im_end|>", "<|im_start|>", "</s>"]:
        if tok in raw:
            raw = raw[:raw.find(tok)]
    raw = raw.strip()
    return parse_intent_keyword(raw)


# ─────────────────────────────────────────────────────────────
# モックデータ（test_prompt.py と同じ定義）
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
        import datetime as dt
        return dt.datetime.strptime(self.date_str, "%Y-%m-%d")


def _r(d, c, n, p, t):
    return MockReceipt(d, c, n, p, t)


MOCK_PATTERNS = {
    "A": [  # 食費・交通の便利支出が多い
        _r("2026-04-01", "食費",        "便利", "現金",            980),
        _r("2026-04-02", "食費",        "便利", "現金",           1250),
        _r("2026-04-03", "交通・移動費", "便利", "QRコード決済",    850),
        _r("2026-04-04", "食費",        "必要", "クレジットカード", 3200),
        _r("2026-04-05", "日用品・雑貨費","必要","現金",             780),
        _r("2026-04-08", "食費",        "便利", "現金",           1580),
        _r("2026-04-09", "交通・移動費", "便利", "QRコード決済",   1200),
        _r("2026-04-10", "食費",        "便利", "現金",            720),
        _r("2026-04-11", "食費",        "必要", "クレジットカード", 2800),
        _r("2026-04-14", "通信費",       "必要", "クレジットカード",3500),
        _r("2026-04-15", "食費",        "便利", "現金",            980),
        _r("2026-04-16", "交通・移動費", "便利", "QRコード決済",    650),
        _r("2026-04-17", "サブスク費",   "便利", "クレジットカード",1500),
        _r("2026-04-20", "食費",        "便利", "現金",           1100),
        _r("2026-04-22", "日用品・雑貨費","必要","現金",            1200),
        _r("2026-04-25", "食費",        "必要", "クレジットカード", 2500),
        _r("2026-04-28", "交通・移動費", "便利", "QRコード決済",    780),
        _r("2026-04-29", "食費",        "便利", "現金",            850),
    ],
    "B": [  # 趣味・外食の贅沢支出が多い
        _r("2026-04-01", "食費",        "必要", "クレジットカード", 3500),
        _r("2026-04-02", "趣味・娯楽費", "贅沢", "クレジットカード",4800),
        _r("2026-04-03", "食費",        "贅沢", "クレジットカード", 6200),
        _r("2026-04-05", "日用品・雑貨費","必要","現金",              800),
        _r("2026-04-07", "趣味・娯楽費", "贅沢", "クレジットカード",3200),
        _r("2026-04-09", "食費",        "贅沢", "クレジットカード", 5500),
        _r("2026-04-11", "服・美容費",   "贅沢", "クレジットカード",8900),
        _r("2026-04-12", "交通・移動費", "必要", "QRコード決済",    550),
        _r("2026-04-14", "通信費",       "必要", "クレジットカード",3500),
        _r("2026-04-16", "趣味・娯楽費", "贅沢", "クレジットカード",2700),
        _r("2026-04-18", "食費",        "贅沢", "クレジットカード", 4300),
        _r("2026-04-20", "サブスク費",   "便利", "クレジットカード",2800),
        _r("2026-04-22", "交際費",       "贅沢", "クレジットカード",6000),
        _r("2026-04-25", "食費",        "必要", "クレジットカード", 2900),
        _r("2026-04-28", "趣味・娯楽費", "贅沢", "クレジットカード",3500),
    ],
    "C": [  # バランス型（必要支出中心）
        _r("2026-04-01", "食費",        "必要", "クレジットカード", 3800),
        _r("2026-04-03", "交通・移動費", "必要", "QRコード決済",   1200),
        _r("2026-04-05", "食費",        "必要", "クレジットカード", 4200),
        _r("2026-04-07", "日用品・雑貨費","必要","QRコード決済",    1500),
        _r("2026-04-09", "食費",        "便利", "現金",             980),
        _r("2026-04-10", "通信費",       "必要", "クレジットカード",3500),
        _r("2026-04-12", "医療・健康費", "必要", "クレジットカード",1800),
        _r("2026-04-14", "食費",        "必要", "クレジットカード", 3600),
        _r("2026-04-16", "趣味・娯楽費", "贅沢", "クレジットカード",1500),
        _r("2026-04-18", "交通・移動費", "必要", "QRコード決済",    800),
        _r("2026-04-20", "食費",        "必要", "クレジットカード", 3300),
        _r("2026-04-22", "日用品・雑貨費","必要","QRコード決済",    1200),
        _r("2026-04-25", "食費",        "便利", "現金",             750),
        _r("2026-04-28", "サブスク費",   "便利", "クレジットカード", 980),
    ],
}

# ─────────────────────────────────────────────────────────────
# テストケース定義
# ─────────────────────────────────────────────────────────────
# (質問文, 期待意図, 期待スコアリング理由)

TEST_CASES = [
    # ── advice ───────────────────────────────────────────
    ("節約のコツを教えて",                   "advice",   "典型: 節約キーワード"),
    ("無駄遣いはどこですか？",               "advice",   "「節約」なし → keyword miss?"),
    ("出費を削減するには？",                 "advice",   "削減キーワード"),
    ("どこを減らせばいいですか",             "advice",   "「節約/削減/アドバイス」なし → other miss"),
    ("もっと貯金を増やしたい",              "advice",   "「節約」なし → other miss"),
    ("お金の使いすぎを直したい",            "advice",   "キーワードなし → other miss"),

    # ── overview ─────────────────────────────────────────
    ("支出の全体像を教えて",                "overview", "「全体」キーワード"),
    ("最近の傾向を教えてください",          "overview", "「傾向」キーワード"),
    ("今月どれくらい使いましたか？",        "overview", "「全体/推移/概要/傾向」なし → other miss"),
    ("先月と比べてどうですか",              "overview", "「推移」なし → other miss"),
    ("毎月いくら使っていますか",            "overview", "キーワードなし → other miss"),
    ("今月の支出の概要を見せて",            "overview", "「概要」キーワード"),

    # ── category ─────────────────────────────────────────
    ("食費はどのくらい使っていますか",      "category", "「食費」キーワード"),
    ("交通費について教えて",               "category", "「交通」キーワード"),
    ("趣味・娯楽費の詳細を教えて",         "category", "「詳細」キーワード"),
    ("サブスクの費用は？",                 "category", "キーワードなし → other miss"),
    ("外食にいくら使っている？",           "category", "キーワードなし → other miss"),
    ("コンビニによく行きますか？",         "category", "キーワードなし → other miss"),
    ("日用品への支出を教えて",             "category", "キーワードなし → other miss"),

    # ── payment ──────────────────────────────────────────
    ("現金とカードどちらが多い？",         "payment",  "「現金」「カード」キーワード"),
    ("支払い方法の内訳を教えて",           "payment",  "「支払」キーワード"),
    ("QRコード決済の割合は？",             "payment",  "「決済」キーワード"),
    ("クレジットカードはどのくらい使った？","payment",  "「クレジットカード」→「カード」キーワード"),
    ("電子マネーを使っていますか？",       "payment",  "「電子マネー」→ キーワードなし?"),

    # ── score ────────────────────────────────────────────
    ("家計のスコアは何点ですか",           "score",    "「スコア」「点数」キーワード"),
    ("家計は健全ですか？",                "score",    "「健全」キーワード"),
    ("今月の家計評価を教えて",            "score",    "「評価」キーワード"),
    ("私の家計は大丈夫ですか",            "score",    "キーワードなし → other miss"),
    ("贅沢しすぎていますか？",            "score",    "キーワードなし → other miss"),
    ("今月は使いすぎですか",              "score",    "キーワードなし → other miss"),

    # ── weekday ──────────────────────────────────────────
    ("何曜日に一番お金を使っていますか",   "weekday",  "「曜日」キーワード"),
    ("週末に使いすぎていますか？",         "weekday",  "「週末」キーワード"),
    ("支出が多い時期はいつですか",         "weekday",  "「時期」キーワード"),
    ("土曜日の支出を教えて",              "weekday",  "「曜日」なし → other miss"),

    # ── help ─────────────────────────────────────────────
    ("何ができますか？",                  "help",     "「できる」キーワード"),
    ("使い方を教えて",                   "help",     "「使い方」キーワード"),
    ("このAIの機能を教えてください",      "help",     "「機能」キーワード"),
    ("どんな質問に答えられますか",        "help",     "キーワードなし → other miss"),

    # ── other / スコープ外 ────────────────────────────────
    ("今日の天気は？",                   "other",    "スコープ外 → other 正解"),
    ("おすすめのレシピを教えて",         "other",    "スコープ外 → other 正解"),
    ("生活費の内訳を教えて",            "category", "「詳細」含む → category? それとも other?"),

    # ── 複合・曖昧 ────────────────────────────────────────
    ("どこを改善すればいいですか",        "advice",   "キーワードなし → other miss"),
    ("先月より減りましたか",             "overview", "キーワードなし → other miss"),
    ("外食費が多すぎる気がします",        "category", "「食費」含む → category"),
    ("ポイント還元が多い支払い方法は？",  "payment",  "「支払」含む → payment"),
    ("家計改善のためのアドバイスが欲しい","advice",   "「アドバイス」キーワード"),
]

# ─────────────────────────────────────────────────────────────
# システムプロンプト構築（AdviceLLMService.buildSystemPrompt の Python 移植）
# ─────────────────────────────────────────────────────────────

CONVENIENCE_TIPS = {
    "食費": "具体的には、食費ではコンビニや自動販売機などの割高なチャネルを避け、安価なスーパーでのまとめ買いやマイボトルの持参を習慣化してください。",
    "服・美容費": "具体的には、服・美容費では「間に合わせ」の購入を控え、着回しやすい定番アイテムを計画的に買い足すことで、長期的な無駄を減らせます。",
    "日用品・雑貨費": "具体的には、日用品・雑貨費ではストック切れによる場当たり的な購入を避け、安売り時のまとめ買いや大容量パックの活用を意識してください。",
    "交通・移動費": "具体的には、交通・移動費ではタクシーや急ぎの移動を最小限にし、時間に余裕を持って公共交通機関や徒歩を活用することを推奨します。",
    "通信費": "具体的には、通信費では不要なオプションサービスの解約や格安プランへの変更など、一度の手間で済む固定費の削減を優先してください。",
    "サブスク費": "具体的には、サブスク費では「とりあえず登録」を避け、1ヶ月以上使っていないサービスは一旦解約するルールを作ってください。",
    "趣味・娯楽費": "具体的には、趣味・娯楽費では「なんとなく」の課金や遊びを整理し、本当に楽しみたいものに予算を集中させる工夫をしてください。",
    "交際費": "具体的には、交際費では「付き合い」だけでの参加を見直し、本当に大切な人との時間に予算を使うよう意識してください。",
    "その他": "具体的には、使途不明金（小規模な便利支出）を可視化するため、少額決済こそ記録を意識し、財布の紐が緩む「ついでの瞬間」を特定してください。",
}

LUXURY_TIPS = {
    "食費": "具体的には、食費では外食や高級食材の頻度を抑え、特別な日以外は予算内での自炊を心がけることが大切です。",
    "服・美容費": "具体的には、服・美容費ではブランド品や新作の衝動買いを控え、長く愛用できる上質なものを厳選して購入してください。",
    "趣味・娯楽費": "具体的には、趣味・娯楽費では一度のレジャーにかけすぎず、年間予算を決めて計画的に楽しむことが推奨されます。",
    "交際費": "具体的には、交際費では見栄を張るための奢りや高級店での集まりを控え、身の丈に合った交際を心がけてください。",
    "サブスク費": "具体的には、サブスク費ではプレミアムプランなど上位プランへの過剰な課金を見直し、通常プランで十分でないか確認してください。",
    "その他": "具体的には、自分への過度なご褒美を控え、支出が本当に人生の質を高めているか再確認する習慣を持ってください。",
}

ALL_CATEGORIES = [
    "食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費",
    "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費",
    "サブスク費", "勉強費", "その他",
]
WEEKDAY_NAMES = ["", "日", "月", "火", "水", "木", "金", "土"]


def _score_message(score, necessity_ratio, target_ratio=62.5):
    if score >= 90:
        return "節約疲れもなく、浪費の罪悪感もない。お金が最適に使われた完璧に近い状態です。"
    if score >= 70:
        return "合格点です。この範囲を維持できていれば、お金のストレスは最小限です。"
    if score >= 40:
        if necessity_ratio > target_ratio:
            return "必要支出の割合が高めです。固定費などの必要な支出を見直すか、少しの贅沢を取り入れて、生活に心のゆとりを持たせることも検討してみてください。"
        return "必要支出の割合が低く、便利や贅沢への支出が目立ちます。自炊を取り入れたり、贅沢を少し控えることで、より健全な家計に近づけることができます。"
    return "支出のコントロール権を「自分の欲望（便利・贅沢）」に奪われつつあります。家計防衛の観点から赤信号です。"


def _trend_message(monthly_totals, avg):
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
    """AdviceLLMService.buildAnalysisContext の Python 移植"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    if record_count == 0:
        return None

    total_amount = sum(r.total for r in target)
    nec_groups = {}
    for r in target:
        nec_groups.setdefault(r.necessity, []).append(r)
    pay_groups = {}
    for r in target:
        pay_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in pay_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount else 0
    target_ratio = 62.5
    necessity_total = sum(r.total for r in nec_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * (100.0 / target_ratio))) if total_amount else 0

    convenience_total = sum(r.total for r in nec_groups.get("便利", []))
    luxury_total = sum(r.total for r in nec_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount else 0

    saving_potentials = []
    if conv_ratio > 30 and nec_groups.get("便利"):
        cat_totals = {}
        for r in nec_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
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
        tips = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出であり、{luxury_total}円（総支出の{int(lux_ratio)}%）を占めています。"
            f"贅沢支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips}"
        )
    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "特にありません。大きな節約余地がないことをユーザーに明示してください。"
    )

    monthly_groups = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted(monthly_groups)]
    avg_monthly = int(sum(monthly_totals) / len(monthly_totals)) if monthly_totals else 0

    payment_method_message = (
        f"現金支払いが{cash_total}円（総支出の{cash_pct}%）を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
        if cash_pct >= 30
        else "キャッシュレス決済を主体に、ポイント還元などを活用して上手に買い物ができています。"
    )

    necessity_lines = "\n".join(
        f"   - {nec}：{sum(r.total for r in nec_groups.get(nec, []))}円"
        f"（総支出の{int(sum(r.total for r in nec_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

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

    all_payments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
    payment_lines = "\n".join(
        f"   - {m}：{sum(r.total for r in pay_groups.get(m, []))}円"
        f"（総支出の{int(sum(r.total for r in pay_groups.get(m, []))/total_amount*100) if total_amount else 0}%）"
        for m in all_payments
    )

    weekday_groups = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased = []
    wd_lines = []
    for wd in range(1, 8):
        amt = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amt / total_amount * 100) if total_amount else 0
        if pct >= 30:
            biased.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
        wd_lines.append(f"   - {WEEKDAY_NAMES[wd]}曜日：{amt}円（総支出の{pct}%）")
    weekday_trend_message = (
        "曜日による支出の偏りは特にありません。" if not biased
        else f"{'、'.join(biased)}に支出が集中しています。"
    )
    weekday_lines = "\n".join(wd_lines)

    return {
        "period_label": period_label,
        "total_amount": total_amount,
        "record_count": record_count,
        "avg_monthly": avg_monthly,
        "spending_score": spending_score,
        "necessity_ratio": necessity_ratio,
        "score_message": _score_message(spending_score, necessity_ratio),
        "saving_potential_message": saving_potential_message,
        "payment_method_message": payment_method_message,
        "spending_trend_message": _trend_message(monthly_totals, avg_monthly),
        "weekday_trend_message": weekday_trend_message,
        "necessity_lines": necessity_lines,
        "category_lines": category_lines,
        "payment_lines": payment_lines,
        "weekday_lines": weekday_lines,
    }


def section_summary(ctx):
    return (
        f"## 支出サマリー（{ctx['period_label']}）\n"
        f"以下の内容をユーザーに伝えてください：\n"
        f"・合計支出：{ctx['total_amount']}円（{ctx['record_count']}件）\n"
        f"・支出健全度スコア：{ctx['spending_score']}点\n"
        f"・{ctx['score_message']}"
    )


def section_saving(ctx):
    return (
        f"## 節約余地アドバイス\n"
        f"以下の節約アドバイスをユーザーにそのままお伝えください：\n"
        f"{ctx['saving_potential_message']}"
    )


def section_payment(ctx):
    return (
        f"## 支払い方法の分析\n"
        f"{ctx['payment_method_message']}\n\n"
        f"【支払い方法別内訳】\n{ctx['payment_lines']}"
    )


def section_trend(ctx):
    return (
        f"## 支出の推移\n"
        f"{ctx['spending_trend_message']}\n"
        f"月平均支出：{ctx['avg_monthly']}円"
    )


def section_weekday(ctx):
    return (
        f"## 曜日別支出\n"
        f"{ctx['weekday_trend_message']}\n\n"
        f"【曜日別内訳】\n{ctx['weekday_lines']}"
    )


def section_necessity(ctx):
    return f"## 必要度別支出\n【必要度別内訳】\n{ctx['necessity_lines']}"


def section_category(ctx):
    return f"## カテゴリ別支出\n【カテゴリ別内訳】\n{ctx['category_lines']}"


SECTION_BUILDERS = {
    "summary":   section_summary,
    "saving":    section_saving,
    "payment":   section_payment,
    "trend":     section_trend,
    "weekday":   section_weekday,
    "necessity": section_necessity,
    "category":  section_category,
}

HELP_PROMPT = """# 命令文：
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
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。"""

NO_DATA_PROMPT = """# 命令文：
ユーザーはまだ支出データを一件も登録していません。支出レポートは存在しません。
支出データが登録されていないため、支出に基づいたアドバイスや分析はできないことをユーザーに伝えてください。
レシートを登録するよう、丁寧に促してください。

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は200字以内で簡潔に。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。"""

COMMON_FOOTER = """
# 回答の基本原則（最優先）：
1. **数値の透明性**: 金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
2. **簡潔な回答**: 回答は300字以内で簡潔に。
3. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
4. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。"""


def build_system_prompt_xcode(receipts, sections):
    """Swift の buildSystemPrompt を Python 移植"""
    if not sections:
        return HELP_PROMPT

    ctx = build_analysis_context(receipts)
    if ctx is None:
        return NO_DATA_PROMPT

    parts = [
        f"# 命令文：\n"
        f"以下のユーザーの支出レポートから情報を抜き出すことで、ユーザーの質問に回答してください。\n\n"
        f"# 支出レポート（{ctx['period_label']}・合計{ctx['total_amount']}円・{ctx['record_count']}件）："
    ]
    for s in sections:
        if s in SECTION_BUILDERS:
            parts.append(SECTION_BUILDERS[s](ctx))
    parts.append(COMMON_FOOTER)
    return "\n\n".join(parts)


# ─────────────────────────────────────────────────────────────
# 分析ヘルパー
# ─────────────────────────────────────────────────────────────

def classify_all_dry_run():
    """キーワードマッチングの精度分析（LLM不使用）"""
    total = len(TEST_CASES)
    correct = 0
    wrong = []

    print("=" * 88)
    print("【Dry-Run】キーワードマッチング精度テスト（Swift フォールバックロジック）")
    print("=" * 88)
    print(f"{'質問文':<36}  {'期待':<10} {'実際':<10} {'結果':<6} 備考")
    print("-" * 88)

    intent_miss_reasons = {}

    for q, expected, note in TEST_CASES:
        actual = parse_intent_keyword(q)
        ok = actual == expected
        if ok:
            correct += 1
        else:
            key = f"{expected} → {actual}"
            intent_miss_reasons.setdefault(key, []).append(q)
        mark = "✅" if ok else "❌"
        display = q[:34] + ".." if len(q) > 34 else q
        print(f"{display:<36}  {expected:<10} {actual:<10} {mark}     {note}")

    print("-" * 88)
    acc = correct / total * 100
    print(f"\n精度: {correct}/{total} 正解 ({acc:.1f}%)")

    # 意図別集計
    from collections import Counter
    expected_counts = Counter(e for _, e, _ in TEST_CASES)
    actual_counts = Counter(parse_intent_keyword(q) for q, _, _ in TEST_CASES)
    correct_by_intent = Counter()
    total_by_intent = Counter()
    for q, expected, _ in TEST_CASES:
        actual = parse_intent_keyword(q)
        total_by_intent[expected] += 1
        if actual == expected:
            correct_by_intent[expected] += 1

    print("\n【意図別精度】")
    print(f"  {'意図':<10} {'正解/総数':<12} {'精度':<8} sections")
    for intent in ["advice", "overview", "category", "payment", "score", "weekday", "help", "other"]:
        t = total_by_intent[intent]
        c = correct_by_intent[intent]
        pct = (c / t * 100) if t else 0
        secs = ", ".join(SECTIONS_MAP[intent]) if SECTIONS_MAP[intent] else "(データなし)"
        bar = "█" * int(pct // 10) + "░" * (10 - int(pct // 10))
        print(f"  {intent:<10} {c}/{t:<10} {bar} {pct:.0f}%  [{secs}]")

    print("\n【誤分類パターン】")
    if intent_miss_reasons:
        for pattern, qs in sorted(intent_miss_reasons.items()):
            print(f"\n  {pattern}:")
            for q in qs:
                print(f"    ❌ \"{q}\"")
    else:
        print("  なし（全問正解）")

    print("\n【問題の根本原因分析】")
    print("  1. キーワードのカバレッジが低い意図:")
    low_acc = [(intent, correct_by_intent[intent], total_by_intent[intent])
               for intent in ["advice", "overview", "category", "score", "weekday", "help"]
               if total_by_intent[intent] > 0 and correct_by_intent[intent] / total_by_intent[intent] < 0.7]
    for intent, c, t in sorted(low_acc, key=lambda x: x[1]/x[2]):
        print(f"    - {intent}: {c}/{t} ({c/t*100:.0f}%)")
    if not low_acc:
        print("    なし")

    print("\n  2. 多くの質問が「other」に落ちている:")
    other_misses = [q for q, expected, _ in TEST_CASES
                    if parse_intent_keyword(q) == "other" and expected != "other"]
    for q in other_misses:
        expected = next(e for qq, e, _ in TEST_CASES if qq == q)
        print(f"    - \"{q}\" (期待: {expected})")

    print("\n  3. sections不足による回答品質リスク:")
    risky = [
        ("advice (sections: summary, saving)",
         "便利/贅沢 <=30% のとき saving が空 → アドバイス根拠がない"),
        ("overview (sections: summary, trend, necessity)",
         "カテゴリ内訳なし → 「食費が多い月」の理由を説明できない"),
        ("score (sections: summary, necessity)",
         "カテゴリ別内訳なし → スコア改善のための具体策を提示できない"),
    ]
    for intent_sec, risk in risky:
        print(f"    - {intent_sec}")
        print(f"      → {risk}")


def classify_all_stage1(model, tokenizer):
    """LLM を使った Stage 1 分類精度テスト"""
    from mlx_lm import generate as mlx_generate
    total = len(TEST_CASES)
    correct = 0
    wrong = []

    print("=" * 88)
    print("【Stage 1】LLM意図分類精度テスト")
    print("=" * 88)
    print(f"{'質問文':<36}  {'期待':<10} {'LLM':<10} {'KW':<10} {'一致'}")
    print("-" * 88)

    for q, expected, note in TEST_CASES:
        prompt_text = STAGE1_PROMPT_TEMPLATE.format(question=q)
        messages = [{"role": "user", "content": prompt_text}]
        formatted = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
        )
        raw = mlx_generate(model, tokenizer, prompt=formatted, max_tokens=20, verbose=False)
        llm_intent = parse_intent_from_llm_output(raw)
        kw_intent = parse_intent_keyword(q)

        ok = llm_intent == expected
        if ok:
            correct += 1
        else:
            wrong.append((q, expected, llm_intent, kw_intent, raw[:40]))
        mark = "✅" if ok else "❌"
        display = q[:34] + ".." if len(q) > 34 else q
        print(f"{display:<36}  {expected:<10} {llm_intent:<10} {kw_intent:<10} {mark}")

    print("-" * 88)
    acc = correct / total * 100
    print(f"\nLLM精度: {correct}/{total} 正解 ({acc:.1f}%)")

    if wrong:
        print("\n【LLM誤分類の詳細】")
        for q, exp, llm, kw, raw in wrong:
            print(f"\n  ❌ \"{q}\"")
            print(f"     期待={exp}  LLM={llm}  KW={kw}")
            print(f"     LLM生テキスト: \"{raw}\"")


def run_full_pipeline(model, tokenizer, receipts, pattern_name, questions_filter=None, max_tokens=1200):
    """Stage 1 + Stage 2 の完全パイプライン実行"""
    from mlx_lm import generate as mlx_generate

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    results_dir = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(results_dir, exist_ok=True)
    out_path = os.path.join(results_dir, f"{timestamp}_intent_pattern{pattern_name}.txt")

    cases = TEST_CASES
    if questions_filter:
        cases = [(q, e, n) for q, e, n in TEST_CASES if q == questions_filter]
        if not cases:
            print(f"WARNING: '{questions_filter}' に一致する質問がありません")
            cases = TEST_CASES

    print("=" * 88)
    print(f"【Full Pipeline】pattern={pattern_name}  {len(cases)}問")
    print("=" * 88)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(f"=== 2ステージパイプライン / パターン: {pattern_name} ===\n")
        f.write(f"実行日時: {timestamp}\n\n")

        for q, expected, note in cases:
            print(f"\nQ: {q}")
            f.write(f"{'='*60}\n")
            f.write(f"Q: {q}\n期待意図: {expected}  備考: {note}\n\n")

            # Stage 1
            stage1_prompt = STAGE1_PROMPT_TEMPLATE.format(question=q)
            s1_messages = [{"role": "user", "content": stage1_prompt}]
            s1_formatted = tokenizer.apply_chat_template(
                s1_messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
            )
            s1_raw = mlx_generate(model, tokenizer, prompt=s1_formatted, max_tokens=20, verbose=False)
            intent = parse_intent_from_llm_output(s1_raw)
            sections = SECTIONS_MAP[intent]
            intent_ok = "✅" if intent == expected else f"❌ (期待:{expected})"

            print(f"  Stage 1: intent={intent} {intent_ok}  sections={sections}")
            f.write(f"--- Stage 1 ---\n")
            f.write(f"LLM生テキスト: \"{s1_raw.strip()[:60]}\"\n")
            f.write(f"intent: {intent} {intent_ok}\n")
            f.write(f"sections: {sections}\n\n")

            # Stage 2
            system_prompt = build_system_prompt_xcode(receipts, sections)
            s2_messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": f"/no_think {q}"},
            ]
            s2_formatted = tokenizer.apply_chat_template(
                s2_messages, tokenize=False, add_generation_prompt=True, enable_thinking=True
            )
            s2_raw = mlx_generate(model, tokenizer, prompt=s2_formatted, max_tokens=max_tokens, verbose=False)

            # think除去
            ans = s2_raw
            if "</think>" in ans:
                ans = ans.split("</think>")[-1]
            for tok in ["<|im_end|>", "<|im_start|>", "</s>"]:
                if tok in ans:
                    ans = ans[:ans.find(tok)]
            ans = ans.strip()

            print(f"  Stage 2: {ans[:80]}{'...' if len(ans) > 80 else ''}")
            f.write(f"--- Stage 2 ---\n")
            f.write(f"システムプロンプト({len(system_prompt)}文字) sections={sections}\n\n")
            f.write(f"最終回答:\n{ans}\n\n")

            # 品質チェック
            quality_notes = []
            if intent != expected:
                quality_notes.append(f"⚠ 意図分類ミス ({expected}→{intent})")
            if not sections:
                quality_notes.append("⚠ helpフォールバック（データ未使用）")
            elif "other" in intent and len(sections) == 7:
                quality_notes.append("⚠ otherフォールバック（全セクション使用・プロンプト肥大）")
            if len(ans) < 30:
                quality_notes.append("⚠ 回答が短すぎる")
            if quality_notes:
                f.write("品質チェック:\n" + "\n".join(f"  {n}" for n in quality_notes) + "\n")
            f.write("\n")

    print(f"\n結果を保存: {out_path}")


# ─────────────────────────────────────────────────────────────
# エントリポイント
# ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="2ステージ意図分類パイプライン テスト")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run",   action="store_true", help="キーワードマッチングのみ（LLM不要）")
    mode.add_argument("--stage1",    action="store_true", help="Stage 1: LLM分類精度のみ")
    mode.add_argument("--full",      action="store_true", help="Stage 1 + Stage 2 完全パイプライン")
    parser.add_argument("--model",   default="mlx-community/Qwen3-1.7B-4bit", help="mlx_lm モデルパス")
    parser.add_argument("--pattern", default="A", choices=["A", "B", "C"], help="モックデータパターン")
    parser.add_argument("--question",default=None, help="特定の質問文（--full 時のフィルタ）")
    parser.add_argument("--max-tokens", type=int, default=1200, help="Stage 2 最大トークン数")
    parser.add_argument("--print-sections", action="store_true", help="dry-run 時に各セクション内容も表示")
    args = parser.parse_args()

    if args.dry_run:
        classify_all_dry_run()
        if args.print_sections:
            receipts = MOCK_PATTERNS[args.pattern]
            ctx = build_analysis_context(receipts)
            if ctx:
                print("\n" + "=" * 88)
                print(f"【セクション内容プレビュー（パターン {args.pattern}）】")
                for s, builder in SECTION_BUILDERS.items():
                    print(f"\n--- {s} ---")
                    print(builder(ctx)[:300])
        return

    try:
        from mlx_lm import load
    except ImportError:
        print("ERROR: mlx_lm がインストールされていません。`pip install mlx_lm` を実行してください。")
        sys.exit(1)

    print(f"モデルをロード中: {args.model}")
    model, tokenizer = load(args.model)
    print("ロード完了\n")

    if args.stage1:
        classify_all_stage1(model, tokenizer)
    elif args.full:
        receipts = MOCK_PATTERNS[args.pattern]
        run_full_pipeline(model, tokenizer, receipts, args.pattern,
                          questions_filter=args.question, max_tokens=args.max_tokens)


if __name__ == "__main__":
    main()
