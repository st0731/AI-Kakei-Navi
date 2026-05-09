"""
節約AI プロンプトテストスクリプト
Usage:
  python test_prompt.py --variant baseline --pattern A
  python test_prompt.py --variant v1 --pattern all
  python test_prompt.py --list-variants
"""
import argparse
import os
import sys
import datetime
from dataclasses import dataclass
from typing import Optional

# ─────────────────────────────────────────
# Mock データ
# ─────────────────────────────────────────

@dataclass
class MockReceipt:
    date_str: str
    category: str
    necessity: str   # "必要" / "便利" / "贅沢"
    payment: str
    total: int
    is_income: bool = False

    @property
    def receipt_date(self):
        return datetime.datetime.strptime(self.date_str, "%Y-%m-%d")


def _r(date_str, cat, nec, pay, total):
    return MockReceipt(date_str, cat, nec, pay, total)


MOCK_PATTERNS = {
    # Pattern A: 食費・交通の便利支出が多い
    "A": [
        _r("2026-04-01", "食費",       "便利", "現金",          980),
        _r("2026-04-02", "食費",       "便利", "現金",         1250),
        _r("2026-04-03", "交通・移動費", "便利", "QRコード決済", 850),
        _r("2026-04-04", "食費",       "必要", "クレジットカード", 3200),
        _r("2026-04-05", "日用品・雑貨費","必要", "現金",         780),
        _r("2026-04-08", "食費",       "便利", "現金",         1580),
        _r("2026-04-09", "交通・移動費", "便利", "QRコード決済", 1200),
        _r("2026-04-10", "食費",       "便利", "現金",         720),
        _r("2026-04-11", "食費",       "必要", "クレジットカード", 2800),
        _r("2026-04-14", "通信費",      "必要", "クレジットカード", 3500),
        _r("2026-04-15", "食費",       "便利", "現金",         980),
        _r("2026-04-16", "交通・移動費", "便利", "QRコード決済", 650),
        _r("2026-04-17", "サブスク費",  "便利", "クレジットカード", 1500),
        _r("2026-04-20", "食費",       "便利", "現金",         1100),
        _r("2026-04-22", "日用品・雑貨費","必要", "現金",        1200),
        _r("2026-04-25", "食費",       "必要", "クレジットカード", 2500),
        _r("2026-04-28", "交通・移動費", "便利", "QRコード決済",  780),
        _r("2026-04-29", "食費",       "便利", "現金",          850),
    ],
    # Pattern B: 趣味・外食の贅沢支出が多い
    "B": [
        _r("2026-04-01", "食費",       "必要", "クレジットカード", 3500),
        _r("2026-04-02", "趣味・娯楽費", "贅沢", "クレジットカード", 4800),
        _r("2026-04-03", "食費",       "贅沢", "クレジットカード", 6200),
        _r("2026-04-05", "日用品・雑貨費","必要", "現金",          800),
        _r("2026-04-07", "趣味・娯楽費", "贅沢", "クレジットカード", 3200),
        _r("2026-04-09", "食費",       "贅沢", "クレジットカード", 5500),
        _r("2026-04-11", "服・美容費",  "贅沢", "クレジットカード", 8900),
        _r("2026-04-12", "交通・移動費", "必要", "QRコード決済",   550),
        _r("2026-04-14", "通信費",      "必要", "クレジットカード", 3500),
        _r("2026-04-16", "趣味・娯楽費", "贅沢", "クレジットカード", 2700),
        _r("2026-04-18", "食費",       "贅沢", "クレジットカード", 4300),
        _r("2026-04-20", "サブスク費",  "便利", "クレジットカード", 2800),
        _r("2026-04-22", "交際費",      "贅沢", "クレジットカード", 6000),
        _r("2026-04-25", "食費",       "必要", "クレジットカード", 2900),
        _r("2026-04-28", "趣味・娯楽費", "贅沢", "クレジットカード", 3500),
    ],
    # Pattern C: バランス型（必要支出中心）
    "C": [
        _r("2026-04-01", "食費",       "必要", "クレジットカード", 3800),
        _r("2026-04-03", "交通・移動費", "必要", "QRコード決済",   1200),
        _r("2026-04-05", "食費",       "必要", "クレジットカード", 4200),
        _r("2026-04-07", "日用品・雑貨費","必要", "QRコード決済",  1500),
        _r("2026-04-09", "食費",       "便利", "現金",           980),
        _r("2026-04-10", "通信費",      "必要", "クレジットカード", 3500),
        _r("2026-04-12", "医療・健康費", "必要", "クレジットカード", 1800),
        _r("2026-04-14", "食費",       "必要", "クレジットカード", 3600),
        _r("2026-04-16", "趣味・娯楽費", "贅沢", "クレジットカード", 1500),
        _r("2026-04-18", "交通・移動費", "必要", "QRコード決済",    800),
        _r("2026-04-20", "食費",       "必要", "クレジットカード", 3300),
        _r("2026-04-22", "日用品・雑貨費","必要", "QRコード決済",  1200),
        _r("2026-04-25", "食費",       "便利", "現金",            750),
        _r("2026-04-28", "サブスク費",  "便利", "クレジットカード", 980),
    ],
}

TEST_QUESTIONS = [
    ("節約アドバイス",      "節約のアドバイスをして"),
    ("無駄な出費",         "一番無駄な出費はどこ？"),
    ("支出傾向",           "支出の全体的な傾向を教えて"),
    ("食費削減",           "食費を減らすにはどうすればいい？"),
    ("スコープ外",         "今日の天気は？"),
    ("分類基準",           "必要支出と便利支出の違いを教えて"),
    ("アプリ使い方",        "アプリの使い方を教えて"),
]

# ─────────────────────────────────────────
# プロンプト構築（Swift コードの Python 移植）
# ─────────────────────────────────────────

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

ALL_CATEGORIES = [
    "食費", "服・美容費", "日用品・雑貨費", "交通・移動費", "通信費",
    "水道光熱費", "住居費", "医療・健康費", "趣味・娯楽費", "交際費",
    "サブスク費", "勉強費", "その他",
]

WEEKDAY_NAMES = ["", "日", "月", "火", "水", "木", "金", "土"]  # 1-indexed


def build_system_prompt_baseline(receipts: list[MockReceipt]) -> str:
    """Swift の buildSystemPrompt と同等（ベースライン）"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return _no_data_prompt()

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    score_message = _score_message(spending_score, necessity_ratio, target_ratio)

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"便利支出であり、{convenience_total}円（総支出の{int(conv_ratio)}%）を占めています。"
            f"便利支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )

    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出であり、{luxury_total}円（総支出の{int(lux_ratio)}%）を占めています。"
            f"贅沢支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "特にありません。アドバイスをする場合は、大きな節約余地がないことをユーザに明示して下さい。"
    )

    # 月次推移
    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金支払いが{cash_total}円（総支出の{cash_pct}%）を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
        if cash_pct >= 30
        else "キャッシュレス決済を主体に、ポイント還元などを活用して上手に買い物ができています。"
    )

    # 必要度別
    necessity_lines = "\n".join(
        f"   - {nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（総支出の{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    # カテゴリ別
    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_details = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                local_pct = int(v / cat_total * 100) if cat_total > 0 else 0
                nec_details.append(f"{cat}の{nec}支出は{v}円で{cat}の{local_pct}%")
            else:
                nec_details.append(f"{cat}の{nec}支出はありません")
        nec_str = "、".join(nec_details)
        if cat_total > 0:
            cat_lines.append(f"   - {cat}：{cat_total}円（総支出の{cat_pct}%, {nec_str}）")
        else:
            cat_lines.append(f"   - {cat}：支出なし（0円, {nec_str}）")
    category_lines = "\n".join(cat_lines)

    # 支払い方法別
    all_payments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
    payment_lines = "\n".join(
        f"   - {m}：{sum(r.total for r in payment_groups.get(m, []))}円"
        f"（総支出の{int(sum(r.total for r in payment_groups.get(m, []))/total_amount*100) if total_amount else 0}%）"
        for m in all_payments
    )

    # 曜日別
    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1  # Sun=1..Sat=7 (match Swift Calendar.weekday)
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    wd_lines = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
        wd_lines.append(f"   - {WEEKDAY_NAMES[wd]}曜日：{amount}円（総支出の{pct}%）")
    weekday_lines = "\n".join(wd_lines)
    weekday_trend_message = (
        "曜日による支出の偏りは特にありません。"
        if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に支出が集中しています。"
    )

    return f"""# システムロール
あなたは「AI家計ナビ」の節約AIアドバイザーです。ユーザーの質問に答える前に、<think>ブロック内で質問を分類し、参照すべき情報を特定してください。

---
# セクション1：支出分類の基準（必要/便利/贅沢の定義）
- **必要**: 生活維持に不可欠な支出（食材・医療・公共交通・光熱費・家賃など）
- **便利**: 時短や快適さのための支出（コンビニ・デリバリー・タクシー・自動販売機など）
- **贅沢**: 嗜好品・娯楽・外食への支出（レストラン・カフェ・ブランド品・映画・旅行など）

---
# セクション2：アプリの使い方
- レシートを登録するには「支出登録」タブを開き、手動入力か「画像から自動入力」ボタンでレシート写真を使います。
- 分析期間は「設定」タブの「節約AI分析期間」から変更できます（1ヶ月・3ヶ月・6ヶ月・1年・全期間）。
- 必要度スコアの目標比率も「設定」タブで変更できます。
- 登録済みのレシートを編集・削除するには「履歴」タブを使います。
- グラフや集計を見るには「分析」タブを開きます。

---
# セクション3：支出レポート（{period_label}）
合計支出：{total_amount}円（{record_count}件）
支出スコア：{spending_score}点 — {score_message}
節約余地：{saving_potential_message}
支払い方法：{payment_method_message}
支出推移：{spending_trend_message}
曜日傾向：{weekday_trend_message}

## 支出詳細データ
【必要度別】
{necessity_lines}

【カテゴリ別】
{category_lines}

【支払い方法別】
{payment_lines}

【曜日別】
{weekday_lines}

---
# 思考プロセスの指示（<think>ブロック内で必ず実行）
回答前に以下のステップを実行すること：
1. ユーザーの質問を「支出アドバイス」「分類基準」「アプリの使い方」「その他」のいずれかに分類する。
2. 分類結果に対応するセクション（セクション1/2/3）を特定し、そのセクションの情報のみを参照する。
3. 回答の構成（何を・何字で・どの順序で述べるか）を簡潔に計画する。

---
# 回答の基本原則（最優先）：
1. **数値の透明性**: 金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
2. **簡潔な回答**: 回答は300字以内で簡潔に。
3. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
4. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。
5. **格助詞**: 割合・比率を述べる際は「〇〇の割合が〇〇%です」のように「の」でなく「が」を使用してください。例：「必要支出が100%」（×「必要支出の100%」）"""


def build_system_prompt_v1(receipts: list[MockReceipt]) -> str:
    """v1: スコープ制限強化 + フォーマット明示 + ゼロカテゴリ除去"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return _no_data_prompt_v1()

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    score_message = _score_message(spending_score, necessity_ratio, target_ratio)

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"便利支出であり、{convenience_total}円（総支出の{int(conv_ratio)}%）を占めています。"
            f"便利支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )
    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出であり、{luxury_total}円（総支出の{int(lux_ratio)}%）を占めています。"
            f"贅沢支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "特にありません。アドバイスをする場合は、大きな節約余地がないことをユーザに明示して下さい。"
    )

    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金支払いが{cash_total}円（総支出の{cash_pct}%）を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
        if cash_pct >= 30
        else "キャッシュレス決済を主体に、ポイント還元などを活用して上手に買い物ができています。"
    )

    necessity_lines = "\n".join(
        f"   - {nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（総支出の{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    # v1: ゼロカテゴリを除外
    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        if cat_total == 0:
            continue  # ← ゼロ除外
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_details = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                local_pct = int(v / cat_total * 100) if cat_total > 0 else 0
                nec_details.append(f"{cat}の{nec}支出は{v}円で{cat}の{local_pct}%")
        nec_str = "、".join(nec_details)
        cat_lines.append(f"   - {cat}：{cat_total}円（総支出の{cat_pct}%, {nec_str}）")
    category_lines = "\n".join(cat_lines)

    all_payments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
    payment_lines = "\n".join(
        f"   - {m}：{sum(r.total for r in payment_groups.get(m, []))}円"
        f"（総支出の{int(sum(r.total for r in payment_groups.get(m, []))/total_amount*100) if total_amount else 0}%）"
        for m in all_payments
        if sum(r.total for r in payment_groups.get(m, [])) > 0
    )

    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    wd_lines = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        if amount == 0:
            continue
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
        wd_lines.append(f"   - {WEEKDAY_NAMES[wd]}曜日：{amount}円（総支出の{pct}%）")
    weekday_lines = "\n".join(wd_lines)
    weekday_trend_message = (
        "曜日による支出の偏りは特にありません。"
        if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に支出が集中しています。"
    )

    return f"""# システムロール
あなたは「AI家計ナビ」の節約AIアドバイザーです。ユーザーの質問に答える前に、<think>ブロック内で質問を分類し、参照すべき情報を特定してください。

---
# セクション1：支出分類の基準（必要/便利/贅沢の定義）
- **必要**: 生活維持に不可欠な支出（食材・医療・公共交通・光熱費・家賃など）
- **便利**: 時短や快適さのための支出（コンビニ・デリバリー・タクシー・自動販売機など）
- **贅沢**: 嗜好品・娯楽・外食への支出（レストラン・カフェ・ブランド品・映画・旅行など）

---
# セクション2：アプリの使い方
- レシートを登録するには「支出登録」タブを開き、手動入力か「画像から自動入力」ボタンでレシート写真を使います。
- 分析期間は「設定」タブの「節約AI分析期間」から変更できます（1ヶ月・3ヶ月・6ヶ月・1年・全期間）。
- 必要度スコアの目標比率も「設定」タブで変更できます。
- 登録済みのレシートを編集・削除するには「履歴」タブを使います。
- グラフや集計を見るには「分析」タブを開きます。

---
# セクション3：支出レポート（{period_label}）
合計支出：{total_amount}円（{record_count}件）
支出スコア：{spending_score}点 — {score_message}
節約余地：{saving_potential_message}
支払い方法：{payment_method_message}
支出推移：{spending_trend_message}
曜日傾向：{weekday_trend_message}

## 支出詳細データ
【必要度別】
{necessity_lines}

【カテゴリ別（支出ありのみ）】
{category_lines}

【支払い方法別（支出ありのみ）】
{payment_lines}

【曜日別（支出ありのみ）】
{weekday_lines}

---
# 思考プロセスの指示（<think>ブロック内で必ず実行）
回答前に以下のステップを実行すること：
1. 質問が「支出アドバイス」「分類基準」「アプリ使い方」のいずれかに該当するか判定する。該当しない場合は即座にスコープ外として次のステップには進まず回答を返す。
2. 分類結果に対応するセクション（セクション1/2/3）を特定し、そのセクションの情報のみを参照する。
3. 回答の構成（何を・何字で・どの順序で述べるか）を簡潔に計画する。

---
# 回答の基本原則（最優先）：
1. **数値の透明性**: 金額やパーセントを出す際は必ず「〇〇円（総支出の〇〇%）」のように記述して下さい。
2. **簡潔な回答**: 回答は300字以内で簡潔に。
3. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
4. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。
5. **格助詞**: 割合・比率を述べる際は「〇〇の割合が〇〇%です」のように「の」でなく「が」を使用してください。
6. **スコープ制限**: 家計・支出・このアプリ以外の質問（天気・料理レシピ・政治・雑談など）には「その内容はお答えできません。支出や家計についてのご質問をどうぞ。」とだけ返し、説明を付け加えないこと。
7. **フォーマット規則**: 回答は「・」箇条書きか1〜3の短文で統一する。Markdownの見出し（#）・太字（**）・コードブロックは使用しない。数値は「食費 3,200円（総支出の28%）」のように文中に埋め込む。"""


# ─────────────────────────────────────────
# ヘルパー関数
# ─────────────────────────────────────────

def _score_message(score: int, necessity_ratio: float, target_ratio: float) -> str:
    if score >= 90:
        return "節約疲れもなく、浪費の罪悪感もない。お金が最適に使われた完璧に近い状態です。"
    elif score >= 70:
        return "合格点です。この範囲を維持できていれば、お金のストレスは最小限です。"
    elif score >= 40:
        if necessity_ratio > target_ratio:
            return "必要支出の割合が高めです。固定費を見直すか、少しの贅沢を取り入れて生活にゆとりを持たせることも検討してみてください。"
        else:
            return "必要支出の割合が低く、便利や贅沢への支出が目立ちます。手間を惜しまず自炊を取り入れたり、贅沢を少し控えることで健全な家計に近づけます。"
    else:
        return "支出のコントロール権を「自分の欲望（便利・贅沢）」に奪われつつあります。家計防衛の観点から赤信号です。"


def _trend_message(monthly_totals: list[int], avg: float) -> str:
    if len(monthly_totals) < 2:
        return "まだデータが1ヶ月分のみのため、今後の推移に注目していきましょう。"
    latest = monthly_totals[-1]
    previous = monthly_totals[-2]
    if latest < previous and latest < avg:
        return "直近は前月比・平均比ともに減少しており、良いペースで支出をコントロールできています。"
    elif latest > previous and latest > avg:
        return "直近は前月比・平均比ともに増加傾向にあり、支出が膨らみやすい時期かもしれません。引き締めを意識しましょう。"
    elif latest > previous:
        return "平均よりは抑えられていますが、前月よりは増加しています。微増傾向にあるため注意してください。"
    else:
        return "前月よりは減少していますが、平均よりは高い水準です。引き続き、平均ラインを目指して調整していきましょう。"


def _no_data_prompt() -> str:
    return """# システムロール
あなたは「AI家計ナビ」の節約AIアドバイザーです。

# セクション3：支出レポート
ユーザーはまだ支出データを一件も登録していません。支出に基づいたアドバイスや分析はできません。

# 回答の基本原則：
1. **簡潔な回答**: 回答は200字以内で簡潔に。
2. **丁寧な言葉使い**: 敬語を使用して下さい。
3. **誠実な回答**: 質問内容に関連のある回答のみ。"""


def _no_data_prompt_v1() -> str:
    return _no_data_prompt()


def build_system_prompt_v2(receipts: list[MockReceipt]) -> str:
    """v2: apply_chat_template 形式用
    ・<think> 指示を削除（モデルが自然に使うため）
    ・日本語強制・スコープ強化・フォーマット統一
    ・ゼロカテゴリ除去・省スペース表現"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return """あなたは「AI家計ナビ」の節約AIアドバイザーです。日本語のみで回答してください。

支出データはまだ登録されていません。登録後に分析・アドバイスが可能になります。

回答ルール：
・日本語のみ・敬語使用
・200字以内
・家計・支出・アプリ以外の質問は断る
・箇条書きには「・」を使う（#や**は使わない）"""

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"便利支出が{convenience_total}円（{int(conv_ratio)}%）。主に{cats_str}。{tips_str}"
        )
    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出が{luxury_total}円（{int(lux_ratio)}%）。主に{cats_str}。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "大きな節約余地は現在ありません。"
    )

    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金が{cash_total}円（{cash_pct}%）。キャッシュレス切替を検討してください。"
        if cash_pct >= 30
        else "キャッシュレス中心で上手に決済できています。"
    )

    necessity_lines = "\n".join(
        f"・{nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        if cat_total == 0:
            continue
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_parts = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                nec_parts.append(f"{nec}{int(v/cat_total*100)}%")
        nec_str = "/".join(nec_parts)
        cat_lines.append(f"・{cat}：{cat_total}円（{cat_pct}%, {nec_str}）")
    category_lines = "\n".join(cat_lines)

    score_msg = _score_message(spending_score, necessity_ratio, target_ratio)

    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
    weekday_trend_message = (
        "偏りなし" if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に集中"
    )

    return f"""あなたは「AI家計ナビ」の節約AIアドバイザーです。日本語のみで回答してください。

【支出分類の定義】
・必要：食材・医療・公共交通・光熱費・家賃など生活に不可欠な支出
・便利：コンビニ・デリバリー・タクシーなど時短・快適さのための支出
・贅沢：外食・カフェ・娯楽・ブランド品など嗜好品・娯楽への支出

【アプリの使い方】
・支出登録：「支出登録」タブ→手動入力 or 「画像から自動入力」
・分析期間変更：「設定」タブ→「節約AI分析期間」
・レシート編集/削除：「履歴」タブ
・グラフ確認：「分析」タブ

【支出レポート（{period_label}）】
合計：{total_amount}円（{record_count}件）／スコア：{spending_score}点
{score_msg}

【必要度別】
{necessity_lines}

【カテゴリ別（支出あり）】
{category_lines}

【節約余地】{saving_potential_message}
【支払い方法】{payment_method_message}
【支出推移】{spending_trend_message}
【曜日傾向】{weekday_trend_message}

---
回答ルール（最優先）：
1. 日本語のみ・敬語使用
2. 300字以内
3. 箇条書きには「・」を使う（#や**は使わない）
4. 数値は「食費 3,200円（28%）」のように文中に埋め込む
5. 割合は「〇〇が〇〇%」（「〇〇の〇〇%」は不可）
6. 家計・支出・このアプリ以外の質問（天気・料理・雑談等）には「その内容はお答えできません。支出や家計についてご質問ください。」とだけ返す"""


def build_system_prompt_v3(receipts: list[MockReceipt]) -> str:
    """v3: v2 + 語尾ルール（します→しましょう）+ 傾向質問ガイド追加"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return """あなたは「AI家計ナビ」の節約AIアドバイザーです。日本語のみで回答してください。

支出データはまだ登録されていません。登録後に分析・アドバイスが可能になります。

回答ルール：
・日本語のみ・敬語使用
・200字以内
・家計・支出・アプリ以外の質問は断る
・箇条書きには「・」を使う（#や**は使わない）"""

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"便利支出が{convenience_total}円（{int(conv_ratio)}%）。主に{cats_str}。{tips_str}"
        )
    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出が{luxury_total}円（{int(lux_ratio)}%）。主に{cats_str}。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "大きな節約余地は現在ありません。"
    )

    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金が{cash_total}円（{cash_pct}%）。キャッシュレス切替を検討してください。"
        if cash_pct >= 30
        else "キャッシュレス中心で上手に決済できています。"
    )

    necessity_lines = "\n".join(
        f"・{nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        if cat_total == 0:
            continue
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_parts = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                nec_parts.append(f"{nec}{int(v/cat_total*100)}%")
        nec_str = "/".join(nec_parts)
        cat_lines.append(f"・{cat}：{cat_total}円（{cat_pct}%, {nec_str}）")
    category_lines = "\n".join(cat_lines)

    score_msg = _score_message(spending_score, necessity_ratio, target_ratio)

    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
    weekday_trend_message = (
        "偏りなし" if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に集中"
    )

    return f"""あなたは「AI家計ナビ」の節約AIアドバイザーです。日本語のみで回答してください。

【支出分類の定義】
・必要：食材・医療・公共交通・光熱費・家賃など生活に不可欠な支出
・便利：コンビニ・デリバリー・タクシーなど時短・快適さのための支出
・贅沢：外食・カフェ・娯楽・ブランド品など嗜好品・娯楽への支出

【アプリの使い方】
・支出登録：「支出登録」タブ→手動入力 or 「画像から自動入力」
・分析期間変更：「設定」タブ→「節約AI分析期間」
・レシート編集/削除：「履歴」タブ
・グラフ確認：「分析」タブ

【支出レポート（{period_label}）】
合計：{total_amount}円（{record_count}件）／スコア：{spending_score}点
{score_msg}

【必要度別】
{necessity_lines}

【カテゴリ別（支出あり）】
{category_lines}

【節約余地】{saving_potential_message}
【支払い方法】{payment_method_message}
【支出推移】{spending_trend_message}
【曜日傾向】{weekday_trend_message}

---
回答ルール（最優先）：
1. 日本語のみ・敬語使用
2. 400字以内
3. 箇条書きには「・」を使う（#や**は使わない）
4. 数値は「食費 3,200円（28%）」のように文中に埋め込む
5. 割合は「〇〇が〇〇%」（「〇〇の〇〇%」は不可）
6. 家計・支出・このアプリ以外の質問（天気・料理・雑談等）には「その内容はお答えできません。支出や家計についてご質問ください。」とだけ返す
7. アドバイス・提案の語尾は「〜しましょう」「〜てみてください」「〜を検討してください」で表現する。「〜します」は絶対に使わない。
8. 「傾向を教えて」「分析して」など事実確認の質問には、まず【カテゴリ別】や【必要度別】の実データ（金額・比率）を具体的に述べ、そのあとに節約余地がある場合のみ1〜2文のアドバイスを添える。アドバイスから始めないこと。"""


def build_system_prompt_v4(receipts: list[MockReceipt]) -> str:
    """v4: v3 + 無駄な出費質問に数値根拠を求めるルール9追加"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return """あなたは「AI家計ナビ」の節約AIアドバイザーです。日本語のみで回答してください。

支出データはまだ登録されていません。登録後に分析・アドバイスが可能になります。

回答ルール：
・日本語のみ・敬語使用
・200字以内
・家計・支出・アプリ以外の質問は断る
・箇条書きには「・」を使う（#や**は使わない）"""

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"便利支出が{convenience_total}円（{int(conv_ratio)}%）。主に{cats_str}。{tips_str}"
        )
    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"贅沢支出が{luxury_total}円（{int(lux_ratio)}%）。主に{cats_str}。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "大きな節約余地は現在ありません。"
    )

    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金が{cash_total}円（{cash_pct}%）。キャッシュレス切替を検討してください。"
        if cash_pct >= 30
        else "キャッシュレス中心で上手に決済できています。"
    )

    necessity_lines = "\n".join(
        f"・{nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        if cat_total == 0:
            continue
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_parts = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                nec_parts.append(f"{nec}{int(v/cat_total*100)}%")
        nec_str = "/".join(nec_parts)
        cat_lines.append(f"・{cat}：{cat_total}円（{cat_pct}%, {nec_str}）")
    category_lines = "\n".join(cat_lines)

    score_msg = _score_message(spending_score, necessity_ratio, target_ratio)

    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
    weekday_trend_message = (
        "偏りなし" if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に集中"
    )

    # 節約余地ランキング：カテゴリごとに便利+贅沢の合計を算出し、多い順にソート
    waste_by_cat: dict[str, dict] = {}
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        if cat_total == 0:
            continue
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        conv_v = sum(r.total for r in nec_in_cat.get("便利", []))
        lux_v  = sum(r.total for r in nec_in_cat.get("贅沢", []))
        waste_total = conv_v + lux_v
        if waste_total == 0:
            continue
        waste_by_cat[cat] = {
            "cat_total": cat_total,
            "cat_pct": int(cat_total / total_amount * 100) if total_amount else 0,
            "conv": conv_v,
            "conv_pct": int(conv_v / cat_total * 100) if cat_total else 0,
            "lux": lux_v,
            "lux_pct": int(lux_v / cat_total * 100) if cat_total else 0,
            "waste_total": waste_total,
            "waste_pct": int(waste_total / cat_total * 100) if cat_total else 0,
        }

    sorted_waste = sorted(waste_by_cat.items(), key=lambda x: -x[1]["waste_total"])[:3]

    waste_rank_lines = []
    for rank, (cat, d) in enumerate(sorted_waste, 1):
        parts = []
        if d["conv"] > 0:
            parts.append(f"便利 {d['conv']}円（{d['conv_pct']}%）")
        if d["lux"] > 0:
            parts.append(f"贅沢 {d['lux']}円（{d['lux_pct']}%）")
        breakdown = "＋".join(parts)
        waste_rank_lines.append(
            f"第{rank}位：{cat} {d['cat_total']}円（総支出の{d['cat_pct']}%） ／ 節約余地内訳 {breakdown}"
        )
    waste_rank_text = "\n".join(waste_rank_lines) if waste_rank_lines else "特になし"

    # 節約余地セクション：各カテゴリに数値＋具体的アドバイスを統合
    waste_detail_lines = []
    for rank, (cat, d) in enumerate(sorted_waste, 1):
        parts = []
        if d["conv"] > 0:
            parts.append(f"便利 {d['conv']}円（{d['conv_pct']}%）")
        if d["lux"] > 0:
            parts.append(f"贅沢 {d['lux']}円（{d['lux_pct']}%）")
        breakdown = "＋".join(parts)
        tip = CONVENIENCE_TIPS.get(cat, "") if d["conv"] >= d["lux"] else LUXURY_TIPS.get(cat, "")
        waste_detail_lines.append(
            f"第{rank}位 {cat}：{d['cat_total']}円（総支出の{d['cat_pct']}%）、節約余地 {breakdown}\n{tip}"
        )
    waste_detail_text = ("\n\n".join(waste_detail_lines)
                         if waste_detail_lines else "大きな節約余地は現在ありません。")

    return f"""あなたは「AI家計ナビ」の節約AIアドバイザーです。日本語のみで回答してください。

【支出分類の定義】
・必要：食材・医療・公共交通・光熱費・家賃など生活に不可欠な支出
・便利：コンビニ・デリバリー・タクシーなど時短・快適さのための支出
・贅沢：外食・カフェ・娯楽・ブランド品など嗜好品・娯楽への支出

【アプリの使い方】
・支出登録：「支出登録」タブ→手動入力 or 「画像から自動入力」
・分析期間変更：「設定」タブ→「節約AI分析期間」
・レシート編集/削除：「履歴」タブ
・グラフ確認：「分析」タブ

【支出レポート（{period_label}）】
合計：{total_amount}円（{record_count}件）／スコア：{spending_score}点
{score_msg}

【必要度別】
{necessity_lines}

【カテゴリ別（支出あり）】
{category_lines}

【節約余地（便利・贅沢の多いカテゴリ上位3・各カテゴリの具体的なアドバイス付き）】
{waste_detail_text}

【支払い方法】{payment_method_message}
【支出推移】{spending_trend_message}
【曜日傾向】{weekday_trend_message}

---
回答ルール（最優先）：
1. 日本語のみ・敬語使用
2. 400字以内
3. 箇条書きには「・」を使う（#や**は使わない）
4. 数値は「食費 3,200円（28%）」のように文中に埋め込む
5. 割合は「〇〇が〇〇%」（「〇〇の〇〇%」は不可）
6. 家計・支出・このアプリ以外の質問（天気・料理・雑談等）には「その内容はお答えできません。支出や家計についてご質問ください。」とだけ返す
7. アドバイス・提案の語尾は「〜しましょう」「〜てみてください」「〜を検討してください」で表現する。「〜します」は絶対に使わない。
8. 「傾向を教えて」「分析して」など事実確認の質問には、まず【カテゴリ別】や【必要度別】の実データ（金額・比率）を具体的に述べ、そのあとに節約余地がある場合のみ1〜2文のアドバイスを添える。アドバイスから始めないこと。"""


def build_conversation_prompt(system: str, user_message: str,
                              tokenizer=None, enable_thinking: bool = True,
                              no_think: bool = False) -> str:
    """tokenizer が渡された場合は apply_chat_template を使う（正しい Qwen3 形式）。
    no_think=True のときはユーザーメッセージに /no_think を付加して思考を無効化。"""
    if tokenizer is not None:
        msg = user_message + (" /no_think" if no_think else "")
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": msg},
        ]
        return tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True,
            enable_thinking=enable_thinking
        )
    # 旧形式（baseline 互換）
    return f"<|system|>\n{system}\n<|user|>\n{user_message}\n<|assistant|>\n"


def clean_response(text: str) -> str:
    if "</think>" in text:
        parts = text.split("</think>")
        text = parts[-1]
    elif "<think>" in text:
        idx = text.find("<think>")
        text = text[:idx]
    for token in ["<|user|>", "<|system|>", "<|end|>", "</s>"]:
        if token in text:
            text = text[:text.find(token)]
    return text.strip()


def build_system_prompt_xcode(receipts: list[MockReceipt]) -> str:
    """現在の Xcode コード（AdviceLLMService.swift の buildSystemPrompt）を忠実に再現。
    チャットテンプレートは apply_chat_template を使用（ChatML 形式）。"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return """# 命令文：
ユーザーはまだ支出データを一件も登録していません。支出レポートは存在しません。
支出データが登録されていないため、支出に基づいたアドバイスや分析はできないことをユーザーに伝えてください。
レシートを登録するよう、丁寧に促してください。

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は200字以内で簡潔に。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
3. **正確な日本語**: 助詞（は・が・を・に・の・で・へ・と等）を正しく使い、文法的に自然な日本語で回答してください。"""

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    score_message = _score_message(spending_score, necessity_ratio, target_ratio)

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total     = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio  = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals: dict[str, int] = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"{convenience_total}円の便利支出であり、総支出の{int(conv_ratio)}%を占めています。"
            f"便利支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )
    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"{luxury_total}円の贅沢支出であり、総支出の{int(lux_ratio)}%を占めています。"
            f"贅沢支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "特にありません。アドバイスをする場合は、大きな節約余地がないことをユーザに明示して下さい。"
    )

    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金支払いが{cash_total}円で総支出の{cash_pct}%を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
        if cash_pct >= 30
        else "特に改善の必要はないです。"
    )

    # 必要度別
    necessity_lines = "\n".join(
        f"   - {nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（総支出の{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    # カテゴリ別（支出ゼロも含む - Swift コードと同様）
    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_details = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                local_pct = int(v / cat_total * 100) if cat_total > 0 else 0
                nec_details.append(f"{cat}の{nec}支出は{v}円で{cat}の{local_pct}%")
            else:
                nec_details.append(f"{cat}の{nec}支出はありません")
        nec_str = "、".join(nec_details)
        if cat_total > 0:
            cat_lines.append(f"   - {cat}：{cat_total}円（総支出の{cat_pct}%, {nec_str}）")
        else:
            cat_lines.append(f"   - {cat}：支出なし（0円, {nec_str}）")
    category_lines = "\n".join(cat_lines)

    # 支払い方法別
    all_payments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
    payment_lines_list = []
    for m in all_payments:
        amt = sum(r.total for r in payment_groups.get(m, []))
        pct = int(amt / total_amount * 100) if total_amount > 0 else 0
        label = f"{amt}円" if amt > 0 else "支出なし"
        payment_lines_list.append(f"   - {m}：{label}（総支出の{pct}%）")
    payment_lines = "\n".join(payment_lines_list)

    # 曜日別
    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    wd_lines = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
        wd_lines.append(f"   - {WEEKDAY_NAMES[wd]}曜日：{amount}円（総支出の{pct}%）")
    weekday_lines = "\n".join(wd_lines)
    weekday_trend_message = (
        "曜日による支出の偏りは特にありません。"
        if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に支出が集中しています。"
    )

    return f"""# 命令文：
以下のユーザーの支出レポートから情報を抜き出すことで、ユーザの質問に回答して下さい。

# 支出レポート：
対象期間（{period_label}）の合計支出は{total_amount}円（{record_count}件）です。
ユーザの全体的な支出傾向のスコアは{spending_score}点であり、{score_message}
大きな節約余地は、{saving_potential_message}
支払い方法を見ると、{payment_method_message}
支出の推移としては、{spending_trend_message}
曜日別の傾向としては、{weekday_trend_message}

## 支出詳細データ
【必要度別】
{necessity_lines}

【カテゴリ別】
{category_lines}

【支払い方法別】
{payment_lines}

【曜日別】
{weekday_lines}

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は300字以内で簡潔に。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
3. **誠実な回答**: ユーザの質問内容に関連のある回答のみをして下さい。支出レポートに記載されていない数値・割合・提案は絶対に生成しないでください。
4. **正確な日本語**: 助詞（は・が・を・に・の・で・へ・と等）を正しく使い、文法的に自然な日本語で回答してください。"""


def build_system_prompt_v5(receipts: list[MockReceipt]) -> str:
    """v5: 更新後の Xcode コードを再現。ゼロカテゴリ省略 + 節約余地ランキング + スコープ制限 + フォーマット原則。
    /no_think は呼び出し側で付加（VARIANTS_NO_THINK）。"""
    expenses = [r for r in receipts if not r.is_income]
    target = expenses
    period_label = "直近1ヶ月"
    record_count = len(target)
    total_amount = sum(r.total for r in target)

    if record_count == 0:
        return """# 命令文：
ユーザーはまだ支出データを一件も登録していません。支出レポートは存在しません。
支出データが登録されていないため、支出に基づいたアドバイスや分析はできないことをユーザーに伝えてください。
レシートを登録するよう、丁寧に促してください。

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は200字以内で簡潔に。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
3. **スコープ制限**: 支出・節約・家計に関する質問のみ回答してください。それ以外は「その内容はお答えできません。支出や家計についてご質問ください。」とだけ答えてください。
4. **正確な日本語**: 助詞（は・が・を・に・の・で・へ・と等）を正しく使い、文法的に自然な日本語で回答してください。"""

    necessity_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        necessity_groups.setdefault(r.necessity, []).append(r)

    payment_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        payment_groups.setdefault(r.payment, []).append(r)

    cash_total = sum(r.total for r in payment_groups.get("現金", []))
    cash_pct = int(cash_total / total_amount * 100) if total_amount > 0 else 0

    target_ratio = 62.5
    scaling_factor = 100.0 / target_ratio
    necessity_total = sum(r.total for r in necessity_groups.get("必要", []))
    necessity_ratio = (necessity_total / total_amount * 100) if total_amount > 0 else 0
    spending_score = int(max(0, 100 - abs(necessity_ratio - target_ratio) * scaling_factor)) if total_amount > 0 else 0

    score_message = _score_message(spending_score, necessity_ratio, target_ratio)

    convenience_total = sum(r.total for r in necessity_groups.get("便利", []))
    luxury_total     = sum(r.total for r in necessity_groups.get("贅沢", []))
    conv_ratio = (convenience_total / total_amount * 100) if total_amount > 0 else 0
    lux_ratio  = (luxury_total / total_amount * 100) if total_amount > 0 else 0

    saving_potentials = []
    if conv_ratio > 30 and necessity_groups.get("便利"):
        cat_totals: dict[str, int] = {}
        for r in necessity_groups["便利"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/convenience_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(CONVENIENCE_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"{convenience_total}円の便利支出であり、総支出の{int(conv_ratio)}%を占めています。"
            f"便利支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )
    if lux_ratio > 30 and necessity_groups.get("贅沢"):
        cat_totals = {}
        for r in necessity_groups["贅沢"]:
            cat_totals[r.category] = cat_totals.get(r.category, 0) + r.total
        sorted_cats = sorted(cat_totals.items(), key=lambda x: -x[1])[:2]
        cats_str = "、".join(f"{k}({int(v/luxury_total*100)}%)" for k, v in sorted_cats)
        tips_str = "".join(LUXURY_TIPS.get(k, "") for k, _ in sorted_cats)
        saving_potentials.append(
            f"{luxury_total}円の贅沢支出であり、総支出の{int(lux_ratio)}%を占めています。"
            f"贅沢支出は主に{cats_str}で構成されており、ここに大きな節約余地があります。{tips_str}"
        )

    saving_potential_message = (
        "\n".join(saving_potentials) if saving_potentials
        else "特にありません。アドバイスをする場合は、大きな節約余地がないことをユーザに明示して下さい。"
    )

    monthly_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        key = r.receipt_date.strftime("%Y-%m")
        monthly_groups.setdefault(key, []).append(r)
    sorted_months = sorted(monthly_groups.keys())
    monthly_totals = [sum(r.total for r in monthly_groups[k]) for k in sorted_months]
    avg_monthly = sum(monthly_totals) / len(monthly_totals) if monthly_totals else 0
    spending_trend_message = _trend_message(monthly_totals, avg_monthly)

    payment_method_message = (
        f"現金支払いが{cash_total}円で総支出の{cash_pct}%を占めています。そのため、ポイント還元のあるクレジットカードやQRコード決済への切り替えを検討すると、ポイント還元によりお得に買い物ができます。"
        if cash_pct >= 30
        else "特に改善の必要はないです。"
    )

    # 必要度別
    necessity_lines = "\n".join(
        f"   - {nec}：{sum(r.total for r in necessity_groups.get(nec, []))}円"
        f"（総支出の{int(sum(r.total for r in necessity_groups.get(nec, []))/total_amount*100) if total_amount else 0}%）"
        for nec in ["必要", "便利", "贅沢"]
    )

    # カテゴリ別（支出ありのみ - B-3）
    category_groups: dict[str, list[MockReceipt]] = {}
    for r in target:
        category_groups.setdefault(r.category, []).append(r)

    cat_lines = []
    for cat in ALL_CATEGORIES:
        items = category_groups.get(cat, [])
        cat_total = sum(r.total for r in items)
        if cat_total == 0:
            continue  # ゼロ円カテゴリは省略
        cat_pct = int(cat_total / total_amount * 100) if total_amount > 0 else 0
        nec_in_cat: dict[str, list[MockReceipt]] = {}
        for r in items:
            nec_in_cat.setdefault(r.necessity, []).append(r)
        nec_details = []
        for nec in ["必要", "便利", "贅沢"]:
            v = sum(r.total for r in nec_in_cat.get(nec, []))
            if v > 0:
                local_pct = int(v / cat_total * 100) if cat_total > 0 else 0
                nec_details.append(f"{nec}{v}円({local_pct}%)")
        nec_str = "・".join(nec_details)
        cat_lines.append(f"   - {cat}：{cat_total}円（総支出の{cat_pct}%、{nec_str}）")
    category_lines = "\n".join(cat_lines)

    # 支払い方法別
    all_payments = ["現金", "クレジットカード", "QRコード決済", "電子マネー", "その他"]
    payment_lines_list = []
    for m in all_payments:
        amt = sum(r.total for r in payment_groups.get(m, []))
        pct = int(amt / total_amount * 100) if total_amount > 0 else 0
        label = f"{amt}円" if amt > 0 else "支出なし"
        payment_lines_list.append(f"   - {m}：{label}（総支出の{pct}%）")
    payment_lines = "\n".join(payment_lines_list)

    # 曜日別
    weekday_groups: dict[int, list[MockReceipt]] = {}
    for r in target:
        wd = r.receipt_date.isoweekday() % 7 + 1
        weekday_groups.setdefault(wd, []).append(r)
    biased_weekdays = []
    wd_lines = []
    for wd in range(1, 8):
        amount = sum(r.total for r in weekday_groups.get(wd, []))
        pct = int(amount / total_amount * 100) if total_amount > 0 else 0
        if pct >= 30:
            biased_weekdays.append(f"{WEEKDAY_NAMES[wd]}曜日({pct}%)")
        wd_lines.append(f"   - {WEEKDAY_NAMES[wd]}曜日：{amount}円（総支出の{pct}%）")
    weekday_lines = "\n".join(wd_lines)
    weekday_trend_message = (
        "曜日による支出の偏りは特にありません。"
        if not biased_weekdays
        else f"{'、'.join(biased_weekdays)}に支出が集中しています。"
    )

    return f"""# 命令文：
以下のユーザーの支出レポートから情報を抜き出すことで、ユーザの質問に回答して下さい。

# 支出レポート：
対象期間（{period_label}）の合計支出は{total_amount}円（{record_count}件）です。
ユーザの全体的な支出傾向のスコアは{spending_score}点であり、{score_message}
大きな節約余地は、{saving_potential_message}
支払い方法を見ると、{payment_method_message}
支出の推移としては、{spending_trend_message}
曜日別の傾向としては、{weekday_trend_message}

## 支出詳細データ
【必要度別】
{necessity_lines}

【カテゴリ別】
{category_lines}

【支払い方法別】
{payment_lines}

【曜日別】
{weekday_lines}

# 回答の基本原則（最優先）：
1. **簡潔な回答**: 回答は300字以内で簡潔に。
2. **丁寧な言葉使い**: 回答では敬語を使用して下さい。
3. **スコープ制限**: 支出・節約アドバイス、支出データの説明（カテゴリ・必要度・曜日・支払い方法）、支出分類の基準（必要/便利/贅沢）、アプリの使い方（登録・分析・設定）に関する質問のみ回答してください。それ以外は「その内容はお答えできません。支出や家計についてご質問ください。」とだけ答えてください。支出レポートに記載されていない数値・割合・提案は絶対に生成しないでください。
4. **正確な日本語**: 助詞（は・が・を・に・の・で・へ・と等）を正しく使い、文法的に自然な日本語で回答してください。
5. **回答形式**: 具体的な金額や割合を引用するときは支出レポートの数値をそのまま使ってください。箇条書き（・）を活用し、1項目は1文以内にまとめてください。"""


# ─────────────────────────────────────────
# バリアント定義
# ─────────────────────────────────────────

VARIANTS = {
    "baseline":       build_system_prompt_baseline,  # 旧 <|system|> 形式
    "v1":             build_system_prompt_v1,         # 旧 <|system|> 形式 + 改善プロンプト
    "v2":             build_system_prompt_v2,         # apply_chat_template + 改善プロンプト（thinking有）
    "v2-nothink":     build_system_prompt_v2,         # v2 + /no_think（思考なし、高速）
    "v3":             build_system_prompt_v3,         # v2-nothink + 語尾ルール + 傾向質問ガイド
    "v4":             build_system_prompt_v4,         # v3 + 無駄な出費に数値根拠を求めるルール9
    "v5":             build_system_prompt_v5,         # ゼロカテゴリ省略 + 節約余地ランキング + スコープ制限
    "xcode":          build_system_prompt_xcode,      # 現在のXcodeコードを忠実再現（thinking有）
    "xcode-nothink":  build_system_prompt_xcode,      # 現在のXcodeコード + /no_think
}

# v2 以降と xcode は apply_chat_template を使う
VARIANTS_USE_CHAT_TEMPLATE = {"v2", "v2-nothink", "v3", "v4", "v5", "xcode", "xcode-nothink"}
VARIANTS_NO_THINK = {"v2-nothink", "v3", "v4", "v5", "xcode-nothink"}


# ─────────────────────────────────────────
# メイン
# ─────────────────────────────────────────

def run_tests(variant: str, pattern: str, model_path: str, max_tokens: int, questions_filter: Optional[str]):
    try:
        from mlx_lm import load, generate as mlx_generate
    except ImportError:
        print("ERROR: mlx_lm がインストールされていません。`pip install mlx_lm` を実行してください。")
        sys.exit(1)

    if variant not in VARIANTS:
        print(f"ERROR: バリアント '{variant}' は未定義です。使用可能: {list(VARIANTS.keys())}")
        sys.exit(1)

    patterns = list(MOCK_PATTERNS.keys()) if pattern == "all" else [pattern.upper()]
    for p in patterns:
        if p not in MOCK_PATTERNS:
            print(f"ERROR: パターン '{p}' は未定義です。使用可能: {list(MOCK_PATTERNS.keys())}")
            sys.exit(1)

    print(f"モデルをロード中: {model_path}")
    model, tokenizer = load(model_path)
    print("ロード完了\n")

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    results_dir = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(results_dir, exist_ok=True)

    for p in patterns:
        receipts = MOCK_PATTERNS[p]
        build_prompt_fn = VARIANTS[variant]
        system_prompt = build_prompt_fn(receipts)

        questions = TEST_QUESTIONS
        if questions_filter:
            questions = [(k, q) for k, q in TEST_QUESTIONS if k == questions_filter]

        out_path = os.path.join(results_dir, f"{timestamp}_{variant}_pattern{p}.txt")
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(f"=== バリアント: {variant} / パターン: {p} ===\n")
            f.write(f"実行日時: {timestamp}\n")
            f.write(f"モデル: {model_path}\n")
            f.write(f"max_tokens: {max_tokens}\n\n")
            f.write("=" * 60 + "\n")
            f.write("【システムプロンプト全文】\n")
            f.write(system_prompt)
            f.write("\n" + "=" * 60 + "\n\n")

            use_chat_template = variant in VARIANTS_USE_CHAT_TEMPLATE
            use_no_think = variant in VARIANTS_NO_THINK

            for q_key, q_text in questions:
                print(f"[{p}] {q_key}: {q_text}")
                prompt = build_conversation_prompt(
                    system_prompt, q_text,
                    tokenizer=tokenizer if use_chat_template else None,
                    no_think=use_no_think,
                )

                raw_output = mlx_generate(
                    model, tokenizer,
                    prompt=prompt,
                    max_tokens=max_tokens,
                    verbose=False,
                )

                cleaned = clean_response(raw_output)

                f.write(f"【質問: {q_key}】\n")
                f.write(f"Q: {q_text}\n\n")
                f.write("--- RAW出力（<think>含む）---\n")
                f.write(raw_output)
                f.write("\n\n--- 最終回答（<think>除去後）---\n")
                f.write(cleaned)
                f.write("\n\n" + "-" * 60 + "\n\n")

                print(f"  → {cleaned[:80]}{'...' if len(cleaned) > 80 else ''}\n")

        print(f"\n結果を保存: {out_path}\n")


def main():
    parser = argparse.ArgumentParser(description="節約AI プロンプトテストスクリプト")
    parser.add_argument("--variant", default="baseline",
                        help=f"テストするバリアント: {list(VARIANTS.keys())} (default: baseline)")
    parser.add_argument("--pattern", default="A",
                        help="モックデータパターン: A / B / C / all (default: A)")
    parser.add_argument("--model", default="mlx-community/Qwen3-1.7B-4bit",
                        help="mlx_lm モデルID またはローカルパス")
    parser.add_argument("--max-tokens", type=int, default=800,
                        help="最大生成トークン数 (default: 800)")
    parser.add_argument("--question", default=None,
                        help="特定の質問キーのみ実行（例: スコープ外）")
    parser.add_argument("--list-variants", action="store_true",
                        help="利用可能なバリアントを表示して終了")
    parser.add_argument("--print-prompt", action="store_true",
                        help="システムプロンプトを表示して終了（推論は実行しない）")

    args = parser.parse_args()

    if args.list_variants:
        print("利用可能なバリアント:")
        for name in VARIANTS:
            print(f"  {name}")
        return

    if args.print_prompt:
        p = args.pattern.upper()
        receipts = MOCK_PATTERNS.get(p, MOCK_PATTERNS["A"])
        fn = VARIANTS.get(args.variant, build_system_prompt_baseline)
        prompt = fn(receipts)
        print(f"=== variant={args.variant}, pattern={p} ===")
        print(f"文字数: {len(prompt)}")
        print()
        print(prompt)
        return

    run_tests(
        variant=args.variant,
        pattern=args.pattern,
        model_path=args.model,
        max_tokens=args.max_tokens,
        questions_filter=args.question,
    )


if __name__ == "__main__":
    main()
