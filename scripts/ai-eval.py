#!/usr/bin/env python3
"""Score any engine on StudyBar's Ask this note, using your own lecture notes.

    python3 scripts/ai-eval.py                          # every local Ollama model
    OPENAI_BASE=https://api.deepseek.com/v1 OPENAI_KEY=sk-… OPENAI_MODEL=deepseek-v4-pro \
      python3 scripts/ai-eval.py                        # …plus a hosted one
    python3 scripts/ai-eval.py --report                 # also write docs/MODEL-EVAL.md

Cases live in eval/cases.json and are questions about notes in the live store, so the
benchmark is the material actually being studied. Four things are checked in code:

  recall     — facts the note contains, present in the answer
  invented   — quotations that appear nowhere in the note (the failure that shipped once)
  math       — equations returned as $…$ rather than raw LaTeX or prose
  table      — a comparison returned as a Markdown table when one was asked for

A fifth, whether a beyond-the-note claim is actually true, is left to a person: cases
carrying `human_check` print their answer for review rather than scoring themselves. A model
grading a model is an opinion, not a measurement.
"""
import argparse, json, os, re, statistics, sys, time, urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/StudyBar/data.json")
CASES = os.path.join(ROOT, "eval", "cases.json")

SYSTEM = ("A student is reading their own lecture note and asks a question about it. Answer from the "
          "note where it covers the ground, and from what you know where it doesn't. Be brief and "
          "concrete. Write ALL mathematics as LaTeX between single dollar signs. Use a Markdown table "
          "when comparing things. Never put words in quotation marks unless they appear in the note "
          "exactly as written. Do not produce work that would be submitted for a grade — the essay, "
          "the problem set solution, the lab answer; explain the method instead.")

def post(url, payload, headers, timeout=600):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", **headers})
    return json.load(urllib.request.urlopen(req, timeout=timeout))

def ollama(model):
    def go(title, body, q):
        r = post("http://localhost:11434/api/chat", {
            "model": model, "stream": False, "options": {"temperature": 0.4, "num_ctx": 8192},
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": f'My note "{title}":\n{body}\n\nQuestion: {q}'}]}, {})
        return r["message"]["content"]
    return go

def openai_compatible(base, key, model):
    def go(title, body, q):
        r = post(base.rstrip("/") + "/chat/completions", {
            "model": model, "max_tokens": 1024, "temperature": 0.4,
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": f'My note "{title}":\n{body}\n\nQuestion: {q}'}]},
            {"Authorization": f"Bearer {key}"})
        return r["choices"][0]["message"]["content"]
    return go

def anthropic(key, model):
    def go(title, body, q):
        r = post("https://api.anthropic.com/v1/messages", {
            "model": model, "max_tokens": 1024, "system": SYSTEM,
            "messages": [{"role": "user", "content": f'My note "{title}":\n{body}\n\nQuestion: {q}'}]},
            {"x-api-key": key, "anthropic-version": "2023-06-01"})
        return "".join(b.get("text", "") for b in r["content"])
    return go

def engines():
    out = []
    for m in (os.environ.get("OLLAMA_MODELS") or "qwen2.5:7b,llama3.1:8b").split(","):
        if m.strip():
            out.append((f"{m.strip()} (local)", ollama(m.strip())))
    if os.environ.get("OPENAI_KEY"):
        base = os.environ.get("OPENAI_BASE", "https://api.openai.com/v1")
        model = os.environ["OPENAI_MODEL"]
        out.append((model, openai_compatible(base, os.environ["OPENAI_KEY"], model)))
    if os.environ.get("ANTHROPIC_KEY"):
        model = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")
        out.append((model, anthropic(os.environ["ANTHROPIC_KEY"], model)))
    return out

def grade(case, answer, note):
    low, hits = answer.lower(), 0
    for m in case["must"]:
        if m.lower() in low:
            hits += 1
    quotes = re.findall(r'"([^"]{20,})"', answer)
    invented = [q for q in quotes if q not in note]
    return {
        "case": case["id"], "kind": case["kind"],
        "recall": hits, "recall_of": len(case["must"]),
        "invented": len(invented),
        "math_ok": (not case["math"]) or bool(re.search(r'(?<!\$)\$[^$\n]+\$', answer)),
        "raw_latex": bool(re.search(r'\\[\(\[]', answer)),
        "table_ok": (not case["table"]) or ("|---" in answer or "| ---" in answer),
        "words": len(answer.split()),
        "needs_human": case.get("human_check"),
        "answer": answer,
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="write docs/MODEL-EVAL.md and eval/results.json")
    ap.add_argument("--show", action="store_true", help="print every answer in full")
    args = ap.parse_args()

    notes = {n["title"]: n["body"] for n in json.load(open(STORE))["notes"]}
    spec = json.load(open(CASES))
    cases = [c for c in spec["cases"] if c["note"] in notes]
    missing = [c["id"] for c in spec["cases"] if c["note"] not in notes]
    if missing:
        print(f"skipping {len(missing)} case(s) whose note isn't in the store: {', '.join(missing)}\n")

    results, reviews = [], []
    for name, call in engines():
        print(f"\n{name}")
        for c in cases:
            body = notes[c["note"]][:24000]
            t = time.time()
            try:
                answer = call(c["note"], body, c["q"])
            except Exception as e:
                print(f"  {c['id']:18} ERROR {e}")
                continue
            r = grade(c, answer, body)
            r.update(engine=name, secs=round(time.time() - t, 1))
            results.append(r)
            recall = f"{r['recall']}/{r['recall_of']}" if r["recall_of"] else "—"
            print(f"  {c['id']:18} {c['kind']:8} recall {recall:>4} · invented {r['invented']} · "
                  f"math {'ok ' if r['math_ok'] else 'MISS'} · table {'ok ' if r['table_ok'] else 'MISS'} · "
                  f"{r['words']:4}w · {r['secs']:5.1f}s")
            if r["needs_human"]:
                reviews.append(r)
            if args.show:
                print("    " + answer.replace("\n", "\n    ")[:1500] + "\n")

    if not results:
        sys.exit("no engine produced a result")

    print("\n=== summary ===")
    rows = []
    for name in dict.fromkeys(r["engine"] for r in results):
        rs = [r for r in results if r["engine"] == name]
        scored = [r for r in rs if r["recall_of"]]
        row = {
            "engine": name,
            "recall": round(100 * sum(r["recall"] for r in scored) / max(1, sum(r["recall_of"] for r in scored))),
            "invented": sum(r["invented"] for r in rs),
            "math": f"{sum(r['math_ok'] for r in rs)}/{len(rs)}",
            "table": f"{sum(r['table_ok'] for r in rs)}/{len(rs)}",
            "raw_latex": sum(r["raw_latex"] for r in rs),
            "median_s": round(statistics.median(r["secs"] for r in rs), 1),
            "cases": len(rs),
        }
        rows.append(row)
        print(f"{row['engine']:26} recall {row['recall']:3}% · invented {row['invented']} · "
              f"math {row['math']} · tables {row['table']} · median {row['median_s']}s")

    if reviews:
        print(f"\n{len(reviews)} answer(s) need a human eye — run with --show to read them:")
        for r in reviews:
            print(f"  {r['engine']:26} {r['case']:18} {r['needs_human']}")

    if args.report:
        os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        payload = {"generated": stamp, "cases": len(cases), "summary": rows,
                   "detail": [{k: v for k, v in r.items() if k != "answer"} for r in results]}
        with open(os.path.join(ROOT, "eval", "results.json"), "w") as f:
            json.dump(payload, f, indent=2)
        md = [f"# Model evaluation — Ask this note\n",
              f"Generated {stamp} by `scripts/ai-eval.py` against {len(cases)} cases in `eval/cases.json`.\n",
              "Questions are asked about real lecture notes; scoring is mechanical (facts present, "
              "quotations that aren't in the note, math delimiters, table syntax). Answers whose "
              "correctness needs judgement are flagged for a human rather than graded by another model.\n",
              "| Engine | Recall | Invented quotes | Math format | Tables | Raw LaTeX | Median |",
              "|---|---|---|---|---|---|---|"]
        for r in rows:
            md.append(f"| `{r['engine']}` | {r['recall']}% | {r['invented']} | {r['math']} | "
                      f"{r['table']} | {r['raw_latex']} | {r['median_s']}s |")
        md += ["", "## What each column means", "",
               "- **Recall** — facts the note actually contains that the answer reproduced.",
               "- **Invented quotes** — quotation marks around words that appear nowhere in the note. Should be 0.",
               "- **Math format** — equations returned as `$…$`, which is what StudyBar renders.",
               "- **Tables** — a Markdown table when the question asked for a comparison.",
               "- **Raw LaTeX** — answers still carrying `\\(…\\)`, which renders as source.",
               "- **Median** — wall-clock seconds per answer, on the machine that ran it.", "",
               "Reproduce with `python3 scripts/ai-eval.py --report`; add a hosted engine by exporting "
               "`OPENAI_BASE` / `OPENAI_KEY` / `OPENAI_MODEL` or `ANTHROPIC_KEY` / `ANTHROPIC_MODEL` first.\n"]
        with open(os.path.join(ROOT, "docs", "MODEL-EVAL.md"), "w") as f:
            f.write("\n".join(md))
        print(f"\nwrote docs/MODEL-EVAL.md and eval/results.json")

if __name__ == "__main__":
    main()
