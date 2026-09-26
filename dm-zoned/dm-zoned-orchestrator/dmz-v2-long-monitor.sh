#!/bin/bash
set -u

INTERVAL="${INTERVAL:-10}"
IOSTAT_EVERY="${IOSTAT_EVERY:-60}"
KEEP_DAYS="${KEEP_DAYS:-7}"
LOGDIR="${LOGDIR:-/var/log/dmz-v2-max4}"

mkdir -p "$LOGDIR"

MAX_R=0
MAX_C=0
MAX_K=0
LAST_IOSTAT=0
LAST_DAY=""

trap 'exit 0' TERM INT

while true; do
    DAY="$(date '+%Y%m%d')"
    NOW="$(date '+%F %T.%3N')"
    EPOCH="$(date +%s)"
    MONLOG="$LOGDIR/monitor-${DAY}.log"
    IOLOG="$LOGDIR/iostat-${DAY}.log"

    if [ "$DAY" != "$LAST_DAY" ]; then
        echo "===== NEW DAY $DAY =====" >>"$MONLOG"

        find "$LOGDIR" -type f \( -name '*.log' -o -name '*.log.gz' \) \
            -mtime "+${KEEP_DAYS}" -delete 2>/dev/null || true

        find "$LOGDIR" -type f -name '*.log' -mtime +0 \
            -exec gzip -f {} \; 2>/dev/null || true

        LAST_DAY="$DAY"
    fi

    PSOUT="$(ps -eLo stat=,wchan:64=,comm=,args= 2>/dev/null || true)"

    R="$(printf '%s\n' "$PSOUT" |
        awk '$1 ~ /^D/ && $2=="dmz_reclaim_copy" {n++} END {print n+0}')"

    C="$(printf '%s\n' "$PSOUT" |
        awk '$1 ~ /^D/ && $2=="dmz_get_chunk_mapping" {n++} END {print n+0}')"

    K="$(printf '%s\n' "$PSOUT" |
        awk '$1 ~ /^D/ && index($0,"kcopyd") {n++} END {print n+0}')"

    case "$R" in ''|*[!0-9]*) R=0 ;; esac
    case "$C" in ''|*[!0-9]*) C=0 ;; esac
    case "$K" in ''|*[!0-9]*) K=0 ;; esac

    [ "$R" -gt "$MAX_R" ] && MAX_R="$R"
    [ "$C" -gt "$MAX_C" ] && MAX_C="$C"
    [ "$K" -gt "$MAX_K" ] && MAX_K="$K"

    VM="$(qm status 100 2>/dev/null | tr '\n' ' ' || true)"
    LOAD="$(cat /proc/loadavg 2>/dev/null || true)"

    MIN_FREE=999999
    MIN_TOTAL=0
    MIN_MAP="none"
    ZERO_COUNT=0
    STATUS_TMP="$(mktemp)"

    for M in $(
        dmsetup ls --target zoned 2>/dev/null |
        awk '{print $1}' |
        grep '^dmz_D' |
        sort
    ); do
        ST="$(dmsetup status "$M" 2>/dev/null || true)"
        printf '%-28s %s\n' "$M" "$ST" >>"$STATUS_TMP"

        CACHE="$(
            printf '%s\n' "$ST" |
            awk '{
                for (i=1; i<=NF; i++) {
                    if ($i=="cache") {
                        print $(i-1);
                        exit
                    }
                }
            }'
        )"

        FREE="${CACHE%/*}"
        TOTAL="${CACHE#*/}"

        case "$FREE:$TOTAL" in
            *[!0-9:/]*|:*|*/|/*) continue ;;
        esac

        if [ -n "$FREE" ] && [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then
            [ "$FREE" -eq 0 ] && ZERO_COUNT=$((ZERO_COUNT + 1))
            if [ "$FREE" -lt "$MIN_FREE" ]; then
                MIN_FREE="$FREE"
                MIN_TOTAL="$TOTAL"
                MIN_MAP="$M"
            fi
        fi
    done

    if [ "$MIN_MAP" != "none" ]; then
        MIN_PCT="$(awk -v f="$MIN_FREE" -v t="$MIN_TOTAL" 'BEGIN { printf "%.1f", 100*f/t }')"
    else
        MIN_FREE=0
        MIN_TOTAL=0
        MIN_PCT="NA"
    fi

    {
        echo
        echo "############################################################"
        echo "TIME $NOW"
        echo "############################################################"
        echo "reclaimD=$R chunkD=$C kcopyD=$K maxR=$MAX_R maxC=$MAX_C maxK=$MAX_K"
        echo "load=$LOAD"
        echo "vm100=$VM"
        echo "min_cache_map=$MIN_MAP min_cache=$MIN_FREE/$MIN_TOTAL min_cache_pct=$MIN_PCT zero_cache_targets=$ZERO_COUNT"

        if [ "$ZERO_COUNT" -gt 0 ]; then
            echo "ALERT=ZERO_FREE_CACHE_TARGET_PRESENT"
        fi

        echo
        echo "PARAMS:"
        P="/sys/module/dm_zoned/parameters"
        if [ -d "$P" ]; then
            for X in \
                reclaim_start \
                reclaim_stop \
                reclaim_idle_sec \
                reclaim_idle_throttle \
                reclaim_poll_sec \
                reclaim_max_active \
                reclaim_slot_retry_ms \
                reclaim_yield_ms
            do
                if [ -r "$P/$X" ]; then
                    printf "%s=%s " "$X" "$(cat "$P/$X")"
                fi
            done
            echo
        else
            echo "dm_zoned module parameters unavailable"
        fi

        echo
        echo "DMSETUP:"
        cat "$STATUS_TMP"

        echo
        echo "D-STATE:"
        ps -eLo pid=,ppid=,stat=,pcpu=,wchan:64=,comm=,args= 2>/dev/null |
        awk '
        $3 ~ /^D/ {
            if ($5=="dmz_reclaim_copy" ||
                $5=="dmz_get_chunk_mapping" ||
                index($0,"kcopyd"))
                print
        }' || true

    } >>"$MONLOG" 2>&1

    rm -f "$STATUS_TMP"

    if [ $((EPOCH - LAST_IOSTAT)) -ge "$IOSTAT_EVERY" ]; then
        {
            echo
            echo "############################################################"
            echo "TIME $(date '+%F %T.%3N')"
            echo "############################################################"
            iostat -xmd 1 2
        } >>"$IOLOG" 2>&1 || true

        LAST_IOSTAT="$EPOCH"
    fi

    sleep "$INTERVAL"
done
