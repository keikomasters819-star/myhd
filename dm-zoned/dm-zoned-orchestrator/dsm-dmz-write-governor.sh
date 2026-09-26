#!/bin/bash

set -u

VMID="${VMID:-100}"
CHECK_SEC="${CHECK_SEC:-5}"
LOG_INTERVAL="${LOG_INTERVAL:-15}"

#
# 如果某盘达到0 free zone：
# 先保持2MiB/s，持续 ZERO_GRACE 秒仍为0时自动 suspend VM。
#
AUTO_SUSPEND_ZERO="${AUTO_SUSPEND_ZERO:-1}"
ZERO_GRACE="${ZERO_GRACE:-30}"

QMP="/run/qemu-server/${VMID}.qmp"

DRIVES=(
    dmz-d01
    dmz-d02
    dmz-d03
    dmz-d04
    dmz-d05
    dmz-d06
    dmz-d07
    dmz-d08
    dmz-d09
    dmz-d10
)

MAPS=(
    dmz_D01_VFG3WPPD
    dmz_D02_VFG2HGLC
    dmz_D03_VEGVUTGZ
    dmz_D04_VFG4D7BD
    dmz_D05_VFG4SNXD
    dmz_D06_VFG50T9D
    dmz_D07_VEGVPHMZ
    dmz_D08_VEGVMATZ
    dmz_D09_VFG3589D
    dmz_D10_VFG48PSD
)


exec 9>/run/dsm-dmz-write-governor.lock

if ! flock -n 9; then
    echo "ERROR: governor already running"
    exit 1
fi


if ! command -v socat >/dev/null 2>&1; then
    echo "ERROR: socat not installed"
    exit 1
fi


#
# Level:
#
# 0 = unlimited
# 1 = 25 MiB/s/disk
# 2 = 20 MiB/s/disk
# 3 = 15 MiB/s/disk
# 4 = 10 MiB/s/disk
# 5 =  6 MiB/s/disk
# 6 =  4 MiB/s/disk
# 7 =  2 MiB/s/disk
#

LEVEL=0
LAST_APPLIED=-1
LAST_LOG=0
ZERO_SINCE=0


limit_bps()
{
    case "$1" in
        0) echo 0 ;;
        1) echo 26214400 ;;
        2) echo 20971520 ;;
        3) echo 15728640 ;;
        4) echo 10485760 ;;
        5) echo 6291456 ;;
        6) echo 4194304 ;;
        7) echo 2097152 ;;
        *) echo 2097152 ;;
    esac
}


limit_name()
{
    case "$1" in
        0) echo "UNLIMITED" ;;
        1) echo "25MiB/s/disk" ;;
        2) echo "20MiB/s/disk" ;;
        3) echo "15MiB/s/disk" ;;
        4) echo "10MiB/s/disk" ;;
        5) echo "6MiB/s/disk" ;;
        6) echo "4MiB/s/disk" ;;
        7) echo "2MiB/s/disk" ;;
    esac
}


#
# 当前free%要求的最小保护级别
#
required_level()
{
    local p="$1"

    if [ "$p" -le 5 ]; then
        echo 7
    elif [ "$p" -le 10 ]; then
        echo 6
    elif [ "$p" -le 20 ]; then
        echo 5
    elif [ "$p" -le 30 ]; then
        echo 4
    elif [ "$p" -le 40 ]; then
        echo 3
    elif [ "$p" -le 50 ]; then
        echo 2
    elif [ "$p" -le 60 ]; then
        echo 1
    else
        echo 0
    fi
}


#
# 当前Level解除到上一档所要求的free%
#
release_threshold()
{
    case "$1" in
        7) echo 12 ;;
        6) echo 20 ;;
        5) echo 30 ;;
        4) echo 40 ;;
        3) echo 50 ;;
        2) echo 60 ;;
        1) echo 75 ;;
        *) echo 101 ;;
    esac
}


get_min_state()
{
    local min_pct=101
    local min_free=0
    local min_total=0
    local min_map=""
    local valid=0

    local m
    local pair
    local free
    local total
    local pct

    for m in "${MAPS[@]}"; do

        pair="$(
            dmsetup status "$m" 2>/dev/null |
            awk '
            {
                for(i=1;i<=NF;i++) {
                    if($i=="random") {
                        print $(i-1)
                        exit
                    }
                }
            }'
        )"

        if [[ "$pair" =~ ^([0-9]+)/([0-9]+)$ ]]; then

            free="${BASH_REMATCH[1]}"
            total="${BASH_REMATCH[2]}"

            if [ "$total" -eq 0 ]; then
                continue
            fi

            pct=$((free * 100 / total))
            valid=$((valid + 1))

            if [ "$pct" -lt "$min_pct" ]; then

                min_pct="$pct"
                min_free="$free"
                min_total="$total"
                min_map="$m"

            elif [ "$pct" -eq "$min_pct" ] &&
                 [ "$free" -lt "$min_free" ]; then

                min_free="$free"
                min_total="$total"
                min_map="$m"

            fi

        fi

    done

    if [ "$valid" -ne 10 ]; then
        return 1
    fi

    echo "$min_pct $min_free $min_total $min_map"
}


#
# 一次QMP连接，同时修改10块盘。
#
apply_qmp_limit()
{
    local bytes="$1"
    local tmp
    local rc

    if [ ! -S "$QMP" ]; then
        echo "ERROR: QMP socket missing: $QMP"
        return 1
    fi

    tmp="$(mktemp)"

    {
        echo '{"execute":"qmp_capabilities"}'

        for id in "${DRIVES[@]}"; do

            printf \
'{"execute":"block_set_io_throttle","arguments":{"id":"%s","bps":0,"bps_rd":0,"bps_wr":%s,"iops":0,"iops_rd":0,"iops_wr":0}}\n' \
                "$id" \
                "$bytes"

        done

    } |
    timeout 10 socat - UNIX-CONNECT:"$QMP" \
        >"$tmp" 2>&1

    rc=$?

    if [ "$rc" -ne 0 ]; then

        echo "ERROR: QMP/socat rc=$rc"
        cat "$tmp"
        rm -f "$tmp"
        return 1

    fi

    if grep -q '"error"' "$tmp"; then

        echo "ERROR: QMP rejected throttle command"
        cat "$tmp"
        rm -f "$tmp"
        return 1

    fi

    rm -f "$tmp"

    return 0
}


apply_level()
{
    local newlevel="$1"
    local bps

    bps="$(limit_bps "$newlevel")"

    echo
    echo "[$(date '+%F %T')] APPLY level=$newlevel limit=$(limit_name "$newlevel")"

    if apply_qmp_limit "$bps"; then

        LAST_APPLIED="$newlevel"
        return 0

    fi

    return 1
}


echo "======================================================"
echo "DSM dm-zoned write governor"
echo "======================================================"
echo "VMID            = $VMID"
echo "check           = ${CHECK_SEC}s"
echo "zero grace      = ${ZERO_GRACE}s"
echo "auto suspend    = $AUTO_SUSPEND_ZERO"
echo "======================================================"


while true; do

    NOW="$(date +%s)"

    #
    # VM没运行时不操作。
    #
    if ! qm status "$VMID" 2>/dev/null |
         grep -q 'status: running'; then

        LAST_APPLIED=-1
        LEVEL=0
        ZERO_SINCE=0

        sleep "$CHECK_SEC"
        continue

    fi


    if [ ! -S "$QMP" ]; then
        sleep "$CHECK_SEC"
        continue
    fi


    if ! STATE="$(get_min_state)"; then

        echo "[$(date '+%F %T')] ERROR: not all 10 dm-zoned targets available"

        sleep "$CHECK_SEC"
        continue

    fi


    read -r MIN_PCT MIN_FREE MIN_TOTAL MIN_MAP <<<"$STATE"

    REQUIRED="$(required_level "$MIN_PCT")"


    #
    # 水位下降：
    # 可以一次直接跳到需要的保护级别。
    #
    if [ "$REQUIRED" -gt "$LEVEL" ]; then

        LEVEL="$REQUIRED"

    #
    # 水位恢复：
    # 使用滞回，每次最多解除一级。
    #
    elif [ "$REQUIRED" -lt "$LEVEL" ]; then

        RELEASE="$(release_threshold "$LEVEL")"

        if [ "$MIN_PCT" -ge "$RELEASE" ]; then
            LEVEL=$((LEVEL - 1))
        fi

    fi


    #
    # Level变化后立即修改10块QEMU盘。
    #
    if [ "$LAST_APPLIED" -ne "$LEVEL" ]; then
        apply_level "$LEVEL" || true
    fi


    #
    # 0 free-zone emergency
    #
    if [ "$MIN_FREE" -eq 0 ]; then

        if [ "$ZERO_SINCE" -eq 0 ]; then

            ZERO_SINCE="$NOW"

            echo
            echo "[$(date '+%F %T')] CRITICAL:"
            echo "$MIN_MAP has 0/$MIN_TOTAL free random zones"
            echo "forcing minimum write rate"

            LEVEL=7

            if [ "$LAST_APPLIED" -ne 7 ]; then
                apply_level 7 || true
            fi

        fi


        ZERO_AGE=$((NOW - ZERO_SINCE))

        if [ "$AUTO_SUSPEND_ZERO" -eq 1 ] &&
           [ "$ZERO_AGE" -ge "$ZERO_GRACE" ]; then

            echo
            echo "======================================================"
            echo "[$(date '+%F %T')] EMERGENCY SUSPEND"
            echo "$MIN_MAP remains at 0 free zones for ${ZERO_AGE}s"
            echo "======================================================"

            qm suspend "$VMID" || true

            ZERO_SINCE=0

            sleep 30
            continue

        fi

    else

        ZERO_SINCE=0

    fi


    #
    # 周期日志
    #
    if [ $((NOW - LAST_LOG)) -ge "$LOG_INTERVAL" ]; then

        echo \
"[$(date '+%F %T')] min=${MIN_PCT}% (${MIN_FREE}/${MIN_TOTAL}) map=${MIN_MAP} level=${LEVEL} limit=$(limit_name "$LEVEL")"

        LAST_LOG="$NOW"

    fi


    sleep "$CHECK_SEC"

done
