#!/bin/bash
# Extract one day's worth of headroom data from
#   /home/sum/.headroom/proxy_savings.json   (filters `history[]` by ISO date)
#   /home/sum/.headroom/logs/proxy.log       (filters lines by `YYYY-MM-DD` prefix)
#
# Usage:
#   ./headroom_extract_day.sh                # defaults to today
#   ./headroom_extract_day.sh 2026-05-06     # explicit date
#
# Output files are written next to the source with _YYYY-MM-DD appended:
#   /home/sum/.headroom/proxy_savings_YYYY-MM-DD.json
#   /home/sum/.headroom/logs/proxy_YYYY-MM-DD.log
set -euo pipefail

DAY="${1:-$(date +%F)}"

if ! [[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "❌ Invalid date '$DAY'. Expected YYYY-MM-DD." >&2
    exit 1
fi

SAVINGS_SRC="${HOME}/.headroom/proxy_savings.json"
LOG_SRC="${HOME}/.headroom/logs/proxy.log"

SAVINGS_DST="${HOME}/.headroom/proxy_savings_${DAY}.json"
LOG_DST="${HOME}/.headroom/logs/proxy_${DAY}.log"

# --- Filter proxy_savings.json by history[].timestamp prefix --------------
if [[ -f "$SAVINGS_SRC" ]]; then
    python3 - "$SAVINGS_SRC" "$SAVINGS_DST" "$DAY" <<'PY'
import json, sys
src, dst, day = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    data = json.load(f)

history = data.get("history", []) if isinstance(data, dict) else []
filtered = [e for e in history if isinstance(e, dict) and str(e.get("timestamp", "")).startswith(day)]

if isinstance(data, dict):
    out = {
        "schema_version": data.get("schema_version"),
        "extracted_for_day": day,
        "lifetime": data.get("lifetime"),
        "display_session": data.get("display_session"),
        "history": filtered,
    }
    out = {k: v for k, v in out.items() if v is not None}
else:
    out = filtered

with open(dst, "w") as f:
    json.dump(out, f, indent=2)

print(f"✓ {dst} ({len(filtered)} history entries for {day})")
PY
else
    echo "⚠ $SAVINGS_SRC not found, skipping" >&2
fi

# --- Filter proxy.log by YYYY-MM-DD line prefix ---------------------------
if [[ -f "$LOG_SRC" ]]; then
    if grep "^${DAY} " "$LOG_SRC" > "$LOG_DST"; then
        lines=$(wc -l < "$LOG_DST")
        echo "✓ $LOG_DST (${lines} lines for ${DAY})"
    else
        # grep exits 1 when no match — keep an empty file as evidence of the run.
        : > "$LOG_DST"
        echo "✓ $LOG_DST (0 lines for ${DAY})"
    fi
else
    echo "⚠ $LOG_SRC not found, skipping" >&2
fi
