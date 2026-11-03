#!/bin/bash
# Ars Contexta — Session Orientation Hook
# Injects workspace structure, identity, methodology, and maintenance signals at session start.
# Also handles session tracking (capture moved here from Stop hook — fires once per session).

# Only run in Ars Contexta vaults
GUARD_DIR="$(cd "$(dirname "$0")" && pwd)"
"$GUARD_DIR/vaultguard.sh" || exit 0

# ── Session tracking (silent — no stdout) ──────────────────────
# SessionStart provides session info as JSON on stdin.
# Read it before any echo statements.

INPUT=$(cat)
SESSION_ID=""
if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
else
  SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//;s/"//')
fi

READ_CONFIG="$GUARD_DIR/read_config.sh"

# [fork patch 2026-11-03] セッション開始の自動コミットより前に origin を取り込む。
# 別PCが先に push していると、取り込む前の "Session start" コミットが ahead/behind の分岐を作っていた。
# fast-forward できるときだけ取り込む（ローカルの変更とぶつかれば git が止めるので何も壊さない）。失敗しても先に進む。
# 元は local patch。nov193/arscontexta フォークに入れたので、プラグインを更新しても残る。
if [ "$(bash "$READ_CONFIG" "git" "true")" = "true" ] && git rev-parse --is-inside-work-tree &>/dev/null; then
  if command -v timeout &>/dev/null; then
    timeout 5 git pull --ff-only --quiet >/dev/null 2>&1 || true
  else
    git pull --ff-only --quiet >/dev/null 2>&1 || true
  fi
fi

if [ -n "$SESSION_ID" ] && [ "$(bash "$READ_CONFIG" "session_capture" "true")" = "true" ]; then
  TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
  mkdir -p ops/sessions

  # Promote previous session if it's a different ID
  if [ -f ops/sessions/current.json ]; then
    if command -v jq &>/dev/null; then
      PREV_ID=$(jq -r '.id // empty' ops/sessions/current.json)
      PREV_STARTED=$(jq -r '.started // empty' ops/sessions/current.json)
    else
      PREV_ID=$(grep -o '"id":"[^"]*"' ops/sessions/current.json | head -1 | sed 's/"id":"//;s/"//')
      PREV_STARTED=$(grep -o '"started":"[^"]*"' ops/sessions/current.json | head -1 | sed 's/"started":"//;s/"//')
    fi

    if [ -n "$PREV_ID" ] && [ "$PREV_ID" != "$SESSION_ID" ]; then
      # Different session — promote previous to timestamped archive
      ARCHIVE_TS="${PREV_STARTED:-$TIMESTAMP}"
      mv ops/sessions/current.json "ops/sessions/${ARCHIVE_TS}.json"
    fi
  fi

  # Write current session
  cat > ops/sessions/current.json << EOF
{
  "id": "$SESSION_ID",
  "started": "$TIMESTAMP",
  "status": "active"
}
EOF

  # Git commit if enabled
  if [ "$(bash "$READ_CONFIG" "git" "true")" = "true" ] && git rev-parse --is-inside-work-tree &>/dev/null; then
    git add ops/sessions/ 2>/dev/null
    [ -f self/goals.md ] && git add self/goals.md 2>/dev/null
    [ -f ops/goals.md ] && git add ops/goals.md 2>/dev/null
    git commit -m "Session start: ${TIMESTAMP}" --quiet --no-verify 2>/dev/null || true
  fi
fi

# Export session ID for later hooks
if [ -n "$CLAUDE_ENV_FILE" ] && [ -n "$SESSION_ID" ]; then
  echo "export CLAUDE_SESSION_ID='$SESSION_ID'" >> "$CLAUDE_ENV_FILE"
fi

# ── Context injection (stdout → conversation) ──────────────────

echo "## Workspace Structure"
echo ""

# Show directory tree (3 levels deep, markdown files only)
if command -v tree &> /dev/null; then
    tree -L 3 --charset ascii -I '.git|node_modules' -P '*.md' .
else
    find . -name "*.md" -not -path "./.git/*" -not -path "*/node_modules/*" -maxdepth 3 | sort | while read -r file; do
        depth=$(echo "$file" | tr -cd '/' | wc -c)
        indent=$(printf '%*s' "$((depth * 2))" '')
        basename=$(basename "$file")
        echo "${indent}${basename}"
    done
fi

echo ""
echo "---"
echo ""

# Previous session state (continuity)
if [ -f ops/sessions/current.json ]; then
  echo "--- Previous session context ---"
  cat ops/sessions/current.json
  echo ""
fi

# Persistent working memory (goals)
if [ -f self/goals.md ]; then
  cat self/goals.md
  echo ""
elif [ -f ops/goals.md ]; then
  cat ops/goals.md
  echo ""
fi

# Identity (if self space enabled)
if [ -f self/identity.md ]; then
  cat self/identity.md self/methodology.md 2>/dev/null
  echo ""
fi

# Learned behavioral patterns (recent methodology notes)
for f in $(ls -t ops/methodology/*.md 2>/dev/null | head -5); do
  head -3 "$f"
done

# Condition-based maintenance signals
# [fork patch 2026-11-03] 解決済みを数えない。直下の *.md だけを見る（archive/ などのサブフォルダは対象外）。
# status が resolved / done / implemented / archived / dissolved / promoted のものは除く。
count_open() {
  local n=0 f
  for f in "$1"/*.md; do
    [ -f "$f" ] || continue
    if head -20 "$f" | grep -qiE '^status:[[:space:]]*"?(resolved|done|implemented|archived|dissolved|promoted)'; then
      continue
    fi
    n=$((n + 1))
  done
  echo "$n"
}
OBS_COUNT=$(count_open ops/observations)
TENS_COUNT=$(count_open ops/tensions)
# [fork patch 2026-11-03] grep -c は 0 件で exit 1 になり、0 が2行返っていたので wc で数える。
SESS_COUNT=$(ls -1 ops/sessions/*.json 2>/dev/null | grep -v current | wc -l | tr -d ' ')

if [ "$OBS_COUNT" -ge 10 ]; then
  echo "CONDITION: $OBS_COUNT pending observations. Consider /rethink."
fi
if [ "$TENS_COUNT" -ge 5 ]; then
  echo "CONDITION: $TENS_COUNT unresolved tensions. Consider /rethink."
fi
if [ "$SESS_COUNT" -ge 5 ]; then
  echo "CONDITION: $SESS_COUNT unprocessed sessions. Consider /remember --mine-sessions."
fi

# [fork patch 2026-11-03] inbox は status: unprocessed（または status 無し）だけを数える。README.md は除く。
# vault 側に ops/scripts/inbox-pressure.mjs があれば、そちらが閾値を持つのでここでは何も出さない。
# 閾値は .arscontexta の inbox_threshold（既定 3）。
if [ ! -f ops/scripts/inbox-pressure.mjs ]; then
  INBOX_COUNT=0
  for f in inbox/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    if head -20 "$f" | grep -qE '^status:' && ! head -20 "$f" | grep -qE '^status:[[:space:]]*"?unprocessed'; then
      continue
    fi
    INBOX_COUNT=$((INBOX_COUNT + 1))
  done
  INBOX_THRESHOLD=$(bash "$READ_CONFIG" "inbox_threshold" "3")
  if [ "$INBOX_COUNT" -ge "$INBOX_THRESHOLD" ]; then
    echo "CONDITION: $INBOX_COUNT items in inbox. Consider /reduce or /pipeline."
  fi
fi

# Workboard reconciliation
if [ -f ops/scripts/reconcile.sh ]; then
  bash ops/scripts/reconcile.sh --compact 2>/dev/null
fi

# Methodology staleness check (Rule Zero)
# [fork patch 2026-11-03] GNU stat では -f がファイルシステム情報を返すので -c を先に試す。
# config が methodology より古い向きのずれも出す（config だけ取り残されるケースを拾えていなかった）。
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
if [ -d ops/methodology ] && [ -f ops/config.yaml ]; then
  CONFIG_MTIME=$(mtime_of ops/config.yaml)
  NEWEST_METH=$(ls -t ops/methodology/*.md 2>/dev/null | head -1)
  if [ -n "$NEWEST_METH" ]; then
    METH_MTIME=$(mtime_of "$NEWEST_METH")
    DAYS_STALE=$(( (CONFIG_MTIME - METH_MTIME) / 86400 ))
    if [ "$DAYS_STALE" -ge 30 ]; then
      echo "CONDITION: Methodology notes are ${DAYS_STALE}+ days behind config changes. Consider /rethink drift."
    elif [ "$DAYS_STALE" -le -30 ]; then
      echo "CONDITION: ops/config.yaml is $(( -DAYS_STALE ))+ days behind methodology notes. Check it still matches practice (/rethink drift)."
    fi
  fi
fi
