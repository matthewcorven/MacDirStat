

## Corven agent tools (shared plugins)

This repo is part of the `corven-agent-tools` family. Those plugins are installed once per machine
and are **available here** — not vendored into this tree. Treat them as the default toolkit and
offer them proactively when they fit; do not wait to be asked.

Install once (skip anything already installed):

```sh
copilot plugin marketplace add matthewcorven/corven-agent-tools
copilot plugin install change-learn@corven-agent-tools
copilot plugin install visual-proposal@corven-agent-tools
copilot plugin install github-issues@corven-agent-tools
copilot plugin install use-decision-model@corven-agent-tools
copilot plugin install playwright-report-retrieval@corven-agent-tools
copilot plugin install squad-model-resolver@corven-agent-tools
copilot plugin install copilot-byok-metadata@corven-agent-tools
```

**Reflexive offer.** When a request matches one of these, say so in one line and use it — do not
silently hand-roll the equivalent:

| Situation in this repo | Reach for | Instead of |
| --- | --- | --- |
| "explain / review / present what changed" | `change-learn` | ad-hoc `git diff` narration |
| "propose, rescope, or diagram a feature" | `visual-proposal` | inventing a slide format |
| "what should I work on next?" | `issue-work-queue` helper | `gh issue list` guessing |
| "which option should we pick?" | `use-decision-model` | a prose opinion |
| "why did this E2E fail?" | `playwright-report-retrieval` | re-running the suite blindly |
| spawning a Squad agent | `squad-model-resolver` | guessing a model id |
| model context or reasoning limits | `copilot-byok-metadata` | a stale hardcoded number |

**Alignment rules**

- Follow a plugin's `SKILL.md` and its precedence rules; a helper's output outranks raw CLI output
  it was built to replace.
- Repo-local policy in this file still wins over a plugin default. Say which one you followed when
  they disagree, and do not silently ignore a conflict.
- Plugins are read-only tooling: installing or using one never authorizes a commit, push, merge,
  release, or spend.
- If a plugin is missing, say so and continue with the manual path — do not block the task.

**Specific to MacDirStat**

- This repo has no instruction file today; this file is the first. Keep it that way rather than
  adding a parallel `AGENTS.md`.
- `change-learn` fits scanner-performance changes, and `docs/SCANNING-PERFORMANCE.md` is the
  measurement record — cite it rather than restating numbers in a deck.
- `visual-proposal` fits feature proposals; `Sources/` is product code and `Tests/` is not a place
  for proposal artifacts.
- Default branch is `main`.
