#!/bin/bash

ROOT="${DMZ_LOG_ROOT:-/mnt/pve/nvme_vmstore/dmz-logs}"
CAP="${DMZ_LOG_CAP_BYTES:-10737418240}"
TARGET="${DMZ_LOG_TARGET_BYTES:-9663676416}"

HEALTH="$ROOT/health"
CSV="$HEALTH/log-size.csv"
LOG="$HEALTH/log-cap.log"

mkdir -p "$HEALTH"

size_now() {
    du -sb "$ROOT" 2>/dev/null | awk '{print $1}'
}

TOTAL=$(size_now)
[ -n "$TOTAL" ] || exit 1

GIB=$(awk -v b="$TOTAL" 'BEGIN{printf "%.3f",b/1073741824}')

[ -s "$CSV" ] ||
echo "timestamp,total_bytes,total_GiB,action" > "$CSV"

if [ "$TOTAL" -le "$CAP" ]; then
    echo "$(date '+%F %T'),$TOTAL,$GIB,keep" >> "$CSV"
    exit 0
fi

logger -p daemon.warning -t dmz-log-cap \
"usage=${GIB}GiB cleanup-start"

find "$ROOT" -type f -name '*.gz' \
-printf '%T@\t%p\n' 2>/dev/null |
sort -n |
cut -f2- |
while IFS= read -r FILE; do
    [ -f "$FILE" ] || continue

    NOW=$(size_now)
    [ "$NOW" -le "$TARGET" ] && break

    echo "$(date '+%F %T') delete $FILE" >> "$LOG"
    rm -f -- "$FILE"
done

TOTAL=$(size_now)
GIB=$(awk -v b="$TOTAL" 'BEGIN{printf "%.3f",b/1073741824}')

if [ "$TOTAL" -le "$TARGET" ]; then
    ACTION=cleaned
else
    ACTION=still_over_limit
    logger -p daemon.err -t dmz-log-cap \
    "cleanup incomplete usage=${GIB}GiB"
fi

echo "$(date '+%F %T'),$TOTAL,$GIB,$ACTION" >> "$CSV"
