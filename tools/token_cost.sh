#!/bin/bash
# agent-resume's implementation cost, by the counter of skill code-minimization (~/.claude/skills/code-minimization/).
# Shared (x1): every file agent-resume ships: its tracked code, but not its tests, docs, tools/ or todo.html
# (todo.html is task-management's client, copied into each project). No client code (x2): nothing is copied per client.
# Reads the tracked files; writes nothing.
# Usage: bash tools/token_cost.sh [-v]   (-v: one row per file)
cd "$(dirname "$0")/.." || exit 1
exec python3 ~/.claude/skills/code-minimization/count_cost.py "$@" \
  --shared $(git ls-files -- ':!:test/' ':!:tools/' ':!:doc/' ':!:*.md' ':!:LICENSE' ':!:.gitignore' ':!:todo.html')
