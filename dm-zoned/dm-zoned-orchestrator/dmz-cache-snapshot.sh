#!/bin/bash

ROOT=/mnt/pve/nvme_vmstore/dmz-logs/cache
LOG="$ROOT/cache.csv"

mkdir -p "$ROOT"

if [ ! -s "$LOG" ]; then
    echo "timestamp,id,mapper,cache_free,cache_total,cache_free_pct,cache_used_pct,random_free,random_total,sequential_free,sequential_total,raw_status" > "$LOG"
fi

dmsetup ls --target zoned 2>/dev/null |
awk '{print $1}' |
grep '^dmz_D' |
sort |
while read -r M; do

    STATUS=$(dmsetup status "$M" 2>/dev/null) || continue

    ID=$(echo "$M" |
        sed -n 's/^dmz_\(D[0-9][0-9]\)_.*/\1/p')

    PARSED=$(echo "$STATUS" | awk '
    {
        C=""
        R=""
        S=""

        for (i=1; i<=NF; i++) {
            if ($i=="cache")
                C=$(i-1)

            if ($i=="random")
                R=$(i-1)

            if ($i=="sequential")
                S=$(i-1)
        }

        split(C,c,"/")
        split(R,r,"/")
        split(S,s,"/")

        print c[1],c[2],r[1],r[2],s[1],s[2]
    }')

    read -r CF CT RF RT SF ST <<< "$PARSED"

    for V in "$CF" "$CT" "$RF" "$RT" "$SF" "$ST"; do
        case "$V" in
            ''|*[!0-9]*)
                logger -p daemon.err -t dmz-cache \
                    "parse error mapper=$M status=$STATUS"
                continue 2
                ;;
        esac
    done

    [ "$CT" -gt 0 ] || continue

    FREEP=$(awk -v f="$CF" -v t="$CT" \
        'BEGIN {printf "%.2f",100*f/t}')

    USEDP=$(awk -v f="$CF" -v t="$CT" \
        'BEGIN {printf "%.2f",100*(t-f)/t}')

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%F %T')" \
        "$ID" \
        "$M" \
        "$CF" "$CT" \
        "$FREEP" "$USEDP" \
        "$RF" "$RT" \
        "$SF" "$ST" \
        "$STATUS" >> "$LOG"

    LOW=$(awk -v p="$FREEP" \
        'BEGIN {print (p < 20)}')

    if [ "$LOW" = "1" ]; then
        logger -p daemon.warning -t dmz-cache \
            "$ID cache free low: ${FREEP}% (${CF}/${CT})"
    fi

done
