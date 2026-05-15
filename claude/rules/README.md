# Claude rules

Short, single-topic rules captured from real friction in this repo. The convention:

1. Hit a non-obvious gotcha while working here? Write the corrected guidance as a file under `claude/rules/<topic>.md` **in the same PR that fixes the underlying problem**.
2. Each rule should lead with the rule itself in one sentence, then explain _why_ it bit us and _how to verify_ you're following it.
3. Cross-reference from `CLAUDE.md` or `README.md` if the rule contradicts something they say (or, better, fix those files in the same PR).

The point isn't documentation completeness — it's that the next Claude session never repeats the mistake. If a rule never bites again, that's success.

Claude Code reads `CLAUDE.md` automatically. `CLAUDE.md` instructs Claude to read everything under `claude/rules/` at session start, so adding a file here propagates without needing to amend `CLAUDE.md` each time.
