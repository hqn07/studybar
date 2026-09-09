# Model evaluation — Ask this note

Generated 2026-09-09 by `scripts/ai-eval.py` against 10 cases in `eval/cases.json`.

Questions are asked about real lecture notes; scoring is mechanical (facts present, quotations that aren't in the note, math delimiters, table syntax). Answers whose correctness needs judgement are flagged for a human rather than graded by another model.

| Engine | Recall | Invented quotes | Math format | Tables | Raw LaTeX | Median |
|---|---|---|---|---|---|---|
| `qwen2.5:7b (local)` | 100% | 2 | 6/10 | 10/10 | 3 | 13.1s |
| `llama3.1:8b (local)` | 86% | 0 | 8/10 | 10/10 | 1 | 11.0s |
| `deepseek-v4-pro` | 100% | 0 | 9/10 | 10/10 | 2 | 14.9s |

## What each column means

- **Recall** — facts the note actually contains that the answer reproduced.
- **Invented quotes** — quotation marks around words that appear nowhere in the note. Should be 0.
- **Math format** — equations returned as `$…$`, which is what StudyBar renders.
- **Tables** — a Markdown table when the question asked for a comparison.
- **Raw LaTeX** — answers still carrying `\(…\)`, which renders as source.
- **Median** — wall-clock seconds per answer, on the machine that ran it.

Reproduce with `python3 scripts/ai-eval.py --report`; add a hosted engine by exporting `OPENAI_BASE` / `OPENAI_KEY` / `OPENAI_MODEL` or `ANTHROPIC_KEY` / `ANTHROPIC_MODEL` first.
