# Project Dashboard LLM Art Design

Date: 2026-09-21
Status: Designed, not built. Source TODO is `[#C]` in `~/roaming/notes/homelab.org`.

**Goal:** Replace the hand-pasted ASCII collection in
`macos/emacs/.emacs.d/lisp/project-dashboard/project-dashboard-art.el` with a
per-project piece drawn once by a hosted LLM, cached on disk, and never
regenerated on render.

## Viability probe (2026-09-21)

Prompt: draw a subject at exactly 8 lines by 40 columns, charset limited to
` .:-=+*#%@`, no prose, no fences. Four subjects per model, scored on line
count, width, and charset. Probe scripts were throwaway under `/tmp`.

Local, via RHEA Ollama (VENGEANCE and MrX2 Ollama were both down):

- qwen3:30b-a3b, qwen3.6:35b-a3b, gemma3:12b: 0 of 12 strict passes. Line
  count usually right, width never right, qwen leaks `/ \ _ ( )`.
  gemma3:12b is charset-clean but draws density blobs, not the subject.

Hosted:

- GPT through `codex exec` (ChatGPT quota, no dollars): 4 of 4 strict passes,
  subjects recognizable.
- Claude Sonnet 5 through `claude -p` (subscription, no dollars): 3 of 4. The
  miss was two lines at width 42.
- Claude Haiku 4.5: 2 of 4, crude drawings.
- OpenRouter cheap lane: gemini-2.5-flash-lite always within 2 columns but
  leaks charset; qwen3.7-flash and glm-5.3-flash return nothing unless
  reasoning is disabled and then draw like the local models. Whole run cost
  under one cent.

Conclusion: local models are out. Frontier models pass on their own and a
10-line normalizer covers the rare slip.

## Decisions

- **Two backends, alternating.** `codex exec` and `claude -p`, both headless,
  both under `timeout`, both spending subscription quota rather than dollars.
  Each generation flips a persisted `next-backend` flag so consecutive pieces
  come from different models. No OpenRouter, no Ollama.
- **Generate once, cache forever.** One file per project under
  `~/.emacs.d/var/project-dashboard/art/<project-name>.txt`, plus
  `state.el` holding the alternation flag. Render reads the cache. A miss
  starts an async generation and shows a collection piece until it lands.
- **Explicit regenerate.** An interactive `project-dashboard-art-regenerate`
  overwrites the cache for the current dashboard and redraws when the process
  exits. This is the only way a cached piece changes.
- **Normalize in elisp, always.** Strip code fences, clip to the line count,
  pad or truncate each line to the width, map any char outside
  ` .:-=+*#%@` to `.`. Applied to every backend result before caching.
- **Size is a defcustom.** Default 12 by 60, since the current collection runs
  that wide and the header centers whatever it gets. Probe was 8 by 40; re-run
  the probe at the chosen size before shipping.
- **Subject is a defcustom list, one picked at random per generation.**
  Seed list: mountain range, sailing ship, city skyline, lighthouse, forest,
  storm cloud, desert, waves. The prompt also names the project so a model
  can lean on it, but no text is allowed in the output.
- **Collection stays.** It is the fallback while a generation runs, the
  fallback when both backends fail, and what `:art-index` in
  `project-dashboard-project-styles` still selects. Fix
  `project-dashboard-art-random` at the same time: it is pinned to index 2
  behind a "for testing" comment.

## Process contract

Both backends are invoked with `make-process`, never synchronously, and
never from the render path.

```
timeout 180 codex exec --skip-git-repo-check -s read-only \
  --output-last-message <tmpfile> "<prompt>"          # stdin from /dev/null
timeout 120 claude -p --model claude-sonnet-5 "<prompt>"
```

The sentinel reads the output, normalizes, writes the cache, flips
`next-backend`, and refreshes the dashboard buffer if it is still live.
Non-zero exit or an empty result leaves the cache untouched and logs one
line to `*Messages*`.

Measured wall time through the CLIs was 20 to 110 seconds, dominated by
agent startup. That is fine for an async one-off and is why render never
waits.

## Out of scope

- Per-render or per-open generation.
- Local Ollama backends. Revisit only if a probe at the chosen size passes.
- Any binding for regenerate until `evil-key-survey.sh` has been run in the
  live session. `project-dashboard-mode` has its own keymap, so a mode-local
  key is the likely home.

## Tests

`macos/emacs/.emacs.d/tests/project-dashboard-art-test.el`, batch-safe, no
network:

- normalizer: fences stripped, short lines padded, long lines cut, extra
  lines dropped, bad chars mapped
- cache round-trip and miss path
- alternation flag flips and persists
- fallback to collection when both backends report failure (processes mocked)
- `project-dashboard-art-random` returns varying indices

## Build estimate

About an hour of elisp and tests, plus one probe run at 12 by 60.
