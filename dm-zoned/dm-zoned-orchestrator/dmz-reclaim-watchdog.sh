#!/bin/bash
set -u

INTERVAL="${INTERVAL:-10}"
LOG_INTERVAL="${LOG_INTERVAL:-60}"

exec 9>/run/dmz-reclaim-watchdog.lock
if ! flock -n 9; then
    echo "ERROR: watchdog already running"
    exit 1
fi

last_log=0

while true; do
    now="$(date +%s)"
    count=0
    fail=0

    mapfile -t MAPS < <(
        dmsetup ls --target zoned 2>/dev/null |
        awk '$1 ~ /^dmz_/ {print $1}' |
        sort
    )

    for m in "${MAPS[@]}"; do
        #
        # 只做一件事：重新调用 dm-zoned 自己的 reclaim scheduler。
        #
        # 不设水位、不判断 busy/idle、不限并发、不做 4K pulse、
        # 不改任何内核参数。
        #
        # 是否真正 reclaim，仍由官方 dm-zoned 内核逻辑决定。
        #
        if dmsetup message "$m" 0 reclaim >/dev/null 2>&1; then
            count=$((count + 1))
        else
            fail=$((fail + 1))
        fi
    done

    if [ $((now - last_log)) -ge "$LOG_INTERVAL" ]; then
        echo "$(date '+%F %T') rearm maps=${#MAPS[@]} ok=$count fail=$fail"
        last_log="$now"
    fi

    sleep "$INTERVAL"
done
