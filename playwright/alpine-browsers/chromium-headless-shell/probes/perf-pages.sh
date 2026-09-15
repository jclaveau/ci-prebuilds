#!/bin/sh
# Hot text working set: distinct 4 KiB pages of the main binary hit by samples.
set -eu
TARGET="$1"; KERNEL="$2"; OUT="$3"; PROBE="$4"; PERF="$5"
READY="/tmp/perf-ready-${TARGET}-${KERNEL}"; rm -f "$READY"; mkdir -p "$OUT"
LOG="${OUT}/${TARGET}-${KERNEL}-pages-probe.log"
node "$PROBE" --target "$TARGET" --kernel "$KERNEL" --seconds 70 --out "$OUT" --ready "$READY" > "$LOG" 2>&1 &
PID=$!; w=0
while [ ! -f "$READY" ]; do kill -0 "$PID" 2>/dev/null || { cat "$LOG"; exit 1; }; [ "$w" -ge 180 ] && exit 1; sleep 1; w=$((w+1)); done
DATA="${OUT}/${TARGET}-${KERNEL}-pages.data"
"$PERF" record -e cpu-clock -F 1999 -a -G / --no-buildid-cache -o "$DATA" -- sleep 20 >/dev/null 2>&1
"$PERF" script -i "$DATA" -F ip,dso 2>/dev/null | grep -E "chrome-headless-shell" | awk '{print substr($1,1,length($1)-3)}' | sort | uniq -c | sort -rn > "${OUT}/${TARGET}-${KERNEL}-pages.txt"
awk -v t="$TARGET" '{n+=$1; c[NR]=$1} END{s=0; for(i=1;i<=NR;i++){s+=c[i]; if(!p50&&s>=n*0.5)p50=i; if(!p90&&s>=n*0.9)p90=i}; printf "%s: main-binary samples %d, distinct 4K pages %d, pages for 50%%=%d 90%%=%d\n", t, n, NR, p50, p90}' "${OUT}/${TARGET}-${KERNEL}-pages.txt"
wait "$PID" || true
