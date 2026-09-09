#!/usr/bin/env python3
"""Head-to-head on YOUR OWN notes: same questions, same prompt, every engine you can reach.

Local models run through Ollama. Cloud models run through any OpenAI-compatible endpoint
(DeepSeek, Qwen, Together, OpenRouter, OpenAI) or Anthropic, if you export a key:

    OPENAI_BASE=https://api.deepseek.com/v1 OPENAI_KEY=sk-... OPENAI_MODEL=deepseek-v4-pro \
    ANTHROPIC_KEY=sk-ant-... ANTHROPIC_MODEL=claude-sonnet-5 \
    python3 scripts/model-bench.py

Scoring is deliberately mechanical — facts that are in the note, quotes that are not,
whether the math came back as $…$ — because a model grading a model is how you get a
leaderboard that agrees with itself and not with reality.
"""
import json, os, re, time, urllib.request, statistics

STORE = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/StudyBar/data.json")
SYS = ("A student is reading their own lecture note and asks a question about it. Answer from "
       "the note where it covers the ground, and from what you know where it doesn't. Be brief "
       "and concrete. Write ALL mathematics as LaTeX between single dollar signs. Use a Markdown "
       "table when comparing things. Never put words in quotation marks unless they appear in "
       "the note exactly as written.")

def notes():
    d = json.load(open(STORE))
    return {n["title"]: n["body"] for n in d["notes"]}

def post(url, payload, headers, timeout=300):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", **headers})
    return json.load(urllib.request.urlopen(req, timeout=timeout))

def ask_ollama(model, note_title, note, q):
    r = post("http://localhost:11434/api/chat", {
        "model": model, "stream": False, "options": {"temperature": 0.4, "num_ctx": 8192},
        "messages": [{"role": "system", "content": SYS},
                     {"role": "user", "content": f'My note "{note_title}":\n{note}\n\nQuestion: {q}'}]}, {})
    return r["message"]["content"]

def ask_openai_compatible(base, key, model, note_title, note, q):
    r = post(base.rstrip("/") + "/chat/completions", {
        "model": model, "max_tokens": 1024, "temperature": 0.4,
        "messages": [{"role": "system", "content": SYS},
                     {"role": "user", "content": f'My note "{note_title}":\n{note}\n\nQuestion: {q}'}]},
        {"Authorization": f"Bearer {key}"})
    return r["choices"][0]["message"]["content"]

def ask_anthropic(key, model, note_title, note, q):
    r = post("https://api.anthropic.com/v1/messages", {
        "model": model, "max_tokens": 1024, "system": SYS,
        "messages": [{"role": "user", "content": f'My note "{note_title}":\n{note}\n\nQuestion: {q}'}]},
        {"x-api-key": key, "anthropic-version": "2023-06-01"})
    return "".join(b.get("text", "") for b in r["content"])

def score(answer, note, must_mention, wants_math, wants_table):
    """Mechanical checks only — each is a fact about the text, not an opinion about it."""
    low = answer.lower()
    hits = sum(1 for m in must_mention if m.lower() in low)
    quotes = re.findall(r'"([^"]{20,})"', answer)
    invented = [q for q in quotes if q not in note]
    return {
        "recall": f"{hits}/{len(must_mention)}",
        "recall_pct": hits / len(must_mention) if must_mention else 0,
        "invented_quotes": len(invented),
        "math_ok": (not wants_math) or bool(re.search(r'(?<!\$)\$[^$\n]+\$', answer)),
        "raw_latex": bool(re.search(r'\\[\(\[]', answer)),
        "table_ok": (not wants_table) or ("|---" in answer or "| ---" in answer),
        "words": len(answer.split()),
    }

CASES = [
    dict(note="Weeks #3 — ORH1030",
         q="What does the lecture say about watering cuttings, and what goes wrong if you overwater?",
         must=["humid", "rot"], math=False, table=False),
    dict(note="Weeks 3 — Gauss's Law II",
         q="State Gauss's law as my note gives it, and explain what the enclosed charge means.",
         must=["flux", "enclosed"], math=True, table=False),
    dict(note="Week 3 — Present Value & Future Value",
         q="My note covers present value. Compare simple interest and compound interest in a table.",
         must=["interest"], math=True, table=True),
]

def run_engine(name, fn):
    rows = []
    for c in CASES:
        body = NOTES[c["note"]][:24000]
        t = time.time()
        try:
            out = fn(c["note"], body, c["q"])
        except Exception as e:
            print(f"  {name}: {c['note'][:22]:24} ERROR {e}")
            continue
        dt = time.time() - t
        s = score(out, body, c["must"], c["math"], c["table"])
        s.update(engine=name, secs=round(dt, 1), note=c["note"])
        rows.append(s)
        print(f"  {name:22} {c['note'][:24]:26} {s['recall']} recall · "
              f"{s['invented_quotes']} invented · math {'ok' if s['math_ok'] else 'MISS'} · "
              f"table {'ok' if s['table_ok'] else 'MISS'} · {s['words']}w · {dt:.0f}s")
    return rows

if __name__ == "__main__":
    NOTES = notes()
    engines = []
    for m in (os.environ.get("OLLAMA_MODELS") or "qwen2.5:7b,llama3.1:8b").split(","):
        m = m.strip()
        if m:
            engines.append((f"ollama/{m}", lambda t, n, q, m=m: ask_ollama(m, t, n, q)))
    if os.environ.get("OPENAI_KEY"):
        base = os.environ.get("OPENAI_BASE", "https://api.openai.com/v1")
        model = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")
        engines.append((model, lambda t, n, q: ask_openai_compatible(base, os.environ["OPENAI_KEY"], model, t, n, q)))
    if os.environ.get("ANTHROPIC_KEY"):
        model = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")
        engines.append((model, lambda t, n, q: ask_anthropic(os.environ["ANTHROPIC_KEY"], model, t, n, q)))

    all_rows = []
    for name, fn in engines:
        print(f"\n{name}")
        all_rows += run_engine(name, fn)

    print("\n=== summary ===")
    for name in dict.fromkeys(r["engine"] for r in all_rows):
        rs = [r for r in all_rows if r["engine"] == name]
        print(f"{name:24} recall {statistics.mean(r['recall_pct'] for r in rs)*100:3.0f}% · "
              f"invented quotes {sum(r['invented_quotes'] for r in rs)} · "
              f"math {sum(r['math_ok'] for r in rs)}/{len(rs)} · "
              f"tables {sum(r['table_ok'] for r in rs)}/{len(rs)} · "
              f"median {statistics.median(r['secs'] for r in rs):.0f}s")
    json.dump(all_rows, open("/tmp/model-bench.json", "w"), indent=2)
