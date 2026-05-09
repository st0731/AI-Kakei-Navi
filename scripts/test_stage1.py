#!/usr/bin/env python3
"""Stage 1 分類プロンプト テストスクリプト"""

import mlx_lm

MODEL_PATH = "/Users/taigasase/.cache/huggingface/hub/models--mlx-community--Qwen3-1.7B-4bit/snapshots/3b1b1768f8f8cf8351c712464f906e86c2b8269e"

VALID_INTENTS = {"advice", "overview", "category", "trend", "necessity", "payment", "weekday", "help", "offtopic"}

TEST_INPUTS = [
    "節約のアドバイスをして",
    "一番無駄な出費はどこ？",
    "支出の全体的な傾向を教えて",
    "今月の食費はいくら？",
]

CATEGORY_LINES = """- advice   : 節約・出費削減アドバイスを求める（例: 節約のコツを教えて、一番無駄な出費はどこ?、どこを削減すべき?）
- overview : 支出全体のサマリー・スコアを知りたい、または分類不明（例: 全体的な傾向は?、家計は健全?）
- category : 特定カテゴリの金額・詳細を知りたい（例: 今月の食費は?、食費はどのくらい?、交通費について教えて）
- trend    : 時系列・月別の推移を知りたい（例: 先月の支出は?、月ごとの変化は?）
- necessity: 必要度別支出を知りたい（例: 贅沢支出はどれくらい?、必要支出の割合は?）
- payment  : 支払い方法について知りたい（例: 現金とカードどちらが多い?）
- weekday  : 曜日の傾向を知りたい（例: 何曜日が多い?）
- help     : このAIの機能・使い方を知りたい（例: 何ができる?）
- offtopic : 家計・支出と無関係な質問（例: 明日の天気は?）"""

def build_prompt(user_text: str, fmt: str = "word") -> str:
    if fmt == "json":
        return f"""/no_think
Classify the following question. Output ONLY a JSON object. No explanation.

Valid intents: advice, overview, category, trend, necessity, payment, weekday, help, offtopic

{CATEGORY_LINES}

CRITICAL: Output ONLY valid JSON like {{"intent": "advice"}}. Use ONLY one of the valid intents above.

Question: {user_text}
Answer:"""
    else:
        return f"""/no_think
Classify the following question. Output ONLY one English word from the list below. No explanation.

Valid words: advice, overview, category, trend, necessity, payment, weekday, help, offtopic

{CATEGORY_LINES}

CRITICAL: Output ONLY one word from the list above. If unsure, output "overview".

Question: {user_text}
Answer:"""

def parse_intent(raw: str, fmt: str = "word") -> tuple[str, bool]:
    import json, re
    # <think>...</think> を除去
    text = raw.split("</think>", 1)[-1] if "</think>" in raw else raw

    if fmt == "json":
        # JSON ブロックを抽出して intent を取得
        match = re.search(r'\{[^}]+\}', text)
        if match:
            try:
                obj = json.loads(match.group())
                word = str(obj.get("intent", "")).lower().strip()
                known = word in VALID_INTENTS
                return (word if known else "overview"), known
            except json.JSONDecodeError:
                pass
        return "overview", False

    word = text.strip().split()[0].lower().rstrip(".,!?") if text.strip() else ""
    known = word in VALID_INTENTS
    return (word if known else "overview"), known

def run_tests(model, tokenizer, fmt: str):
    max_tokens = 20 if fmt == "word" else 50
    label = f"単語出力（max_tokens={max_tokens}）" if fmt == "word" else f"JSON出力（max_tokens={max_tokens}）"
    print(f"\n{'=' * 60}")
    print(f"  {label}")
    print(f"{'=' * 60}")

    for user_text in TEST_INPUTS:
        prompt = build_prompt(user_text, fmt=fmt)
        messages = [{"role": "user", "content": prompt}]
        formatted = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
        raw = mlx_lm.generate(
            model, tokenizer,
            prompt=formatted,
            max_tokens=max_tokens,
            verbose=False,
        )
        intent, known = parse_intent(raw, fmt=fmt)
        status = "✅" if known else "⚠️ 未知語→overview"
        print(f"入力  : {user_text}")
        print(f"生出力: {repr(raw.strip()[:120])}")
        print(f"結果  : {intent}  {status}")
        print("-" * 60)

def main():
    print("モデルをロード中...")
    model, tokenizer = mlx_lm.load(MODEL_PATH)
    print("ロード完了")

    run_tests(model, tokenizer, fmt="word")
    run_tests(model, tokenizer, fmt="json")

if __name__ == "__main__":
    main()
