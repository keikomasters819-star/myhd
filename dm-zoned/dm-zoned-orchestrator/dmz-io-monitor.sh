#!/bin/bash

ROOT=/mnt/pve/nvme_vmstore/dmz-logs/disk-io
LOG="$ROOT/io.csv"
INTERVAL=10

mkdir -p "$ROOT"

declare -A PR PW PRS PWS PIO

header() {
    if [ ! -s "$LOG" ]; then
        echo "timestamp,layer,id,device,read_MB_s,write_MB_s,read_IOPS,write_IOPS,util_pct" > "$LOG"
    fi
}

targets() {
    echo "nvme,NVME,nvme0n1"

    for X in \
      "D01,VFG3WPPD,dmz_D01_VFG3WPPD" \
      "D02,VFG2HGLC,dmz_D02_VFG2HGLC" \
      "D03,VEGVUTGZ,dmz_D03_VEGVUTGZ" \
      "D04,VFG4D7BD,dmz_D04_VFG4D7BD" \
      "D05,VFG4ERMD,dmz_D05_VFG4ERMD" \
      "D06,VFG48PSD,dmz_D06_VFG48PSD" \
      "D07,VFG3589D,dmz_D07_VFG3589D" \
      "D08,VFG2YAJC,dmz_D08_VFG2YAJC" \
      "D09,VFG4SNXD,dmz_D09_VFG4SNXD" \
      "D10,VFG50T9D,dmz_D10_VFG50T9D" \
      "D11,VEGVPHMZ,dmz_D11_VEGVPHMZ" \
      "D12,VEGVMATZ,dmz_D12_VEGVMATZ"
    do
        IFS=, read ID SERIAL DMZ <<< "$X"

        PHY=$(basename "$(readlink -f \
          /dev/disk/by-id/ata-HSH721414ALN6M0_${SERIAL})")

        DMD=$(basename "$(readlink -f /dev/mapper/${DMZ})")

        echo "hc620,$ID,$PHY"
        echo "dmz,$ID,$DMD"
    done

    for X in \
      "cacheA,/dev/md/dmz_cache_A" \
      "cacheB,/dev/md/dmz_cache_B" \
      "vmstore,/dev/md/vm_store"
    do
        IFS=, read ID DEV <<< "$X"
        B=$(basename "$(readlink -f "$DEV")")
        echo "md,$ID,$B"
    done
}

readstat() {
    DEV="$1"

    [ -r "/sys/block/$DEV/stat" ] || return 1

    read R RM RS RMS W WM WS WMS \
         INFLIGHT IOMS WIOMS < "/sys/block/$DEV/stat"

    echo "$R $RS $W $WS $IOMS"
}

init_stats() {
    while IFS=, read LAYER ID DEV; do
        S=$(readstat "$DEV") || continue
        read R RS W WS IO <<< "$S"

        KEY="$LAYER:$ID"
        PR[$KEY]=$R
        PRS[$KEY]=$RS
        PW[$KEY]=$W
        PWS[$KEY]=$WS
        PIO[$KEY]=$IO
    done < <(targets)
}

header
init_stats

while true; do
    T0=$(date +%s)
    sleep "$INTERVAL"
    T1=$(date +%s)

    DT=$((T1-T0))
    [ "$DT" -gt 0 ] || DT=$INTERVAL

    header

    while IFS=, read LAYER ID DEV; do

        S=$(readstat "$DEV") || continue
        read R RS W WS IO <<< "$S"

        KEY="$LAYER:$ID"

        if [ -z "${PR[$KEY]+x}" ]; then
            PR[$KEY]=$R
            PRS[$KEY]=$RS
            PW[$KEY]=$W
            PWS[$KEY]=$WS
            PIO[$KEY]=$IO
            continue
        fi

        DR=$((R-PR[$KEY]))
        DRS=$((RS-PRS[$KEY]))
        DW=$((W-PW[$KEY]))
        DWS=$((WS-PWS[$KEY]))
        DIO=$((IO-PIO[$KEY]))

        RMB=$(awk -v s="$DRS" -v t="$DT" \
            'BEGIN {printf "%.2f",s*512/1048576/t}')

        WMB=$(awk -v s="$DWS" -v t="$DT" \
            'BEGIN {printf "%.2f",s*512/1048576/t}')

        RIOPS=$(awk -v x="$DR" -v t="$DT" \
            'BEGIN {printf "%.2f",x/t}')

        WIOPS=$(awk -v x="$DW" -v t="$DT" \
            'BEGIN {printf "%.2f",x/t}')

        UTIL=$(awk -v x="$DIO" -v t="$DT" \
            'BEGIN {printf "%.2f",x/(t*1000)*100}')

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(date '+%F %T')" \
            "$LAYER" "$ID" "$DEV" \
            "$RMB" "$WMB" \
            "$RIOPS" "$WIOPS" "$UTIL" >> "$LOG"

        PR[$KEY]=$R
        PRS[$KEY]=$RS
        PW[$KEY]=$W
        PWS[$KEY]=$WS
        PIO[$KEY]=$IO

    done < <(targets)
done
