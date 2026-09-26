#!/bin/bash

ROOT=/mnt/pve/nvme_vmstore/dmz-logs/smart
LOG="$ROOT/smart.log"

mkdir -p "$ROOT"

{
    echo
    echo "=================================================="
    echo "$(date '+%F %T')"
    echo "=================================================="

    echo
    echo "===== NVME ====="
    timeout 30 smartctl -a /dev/nvme0n1 2>&1

    for SERIAL in \
      VFG3WPPD VFG2HGLC VEGVUTGZ VFG4D7BD \
      VFG4ERMD VFG48PSD VFG3589D VFG2YAJC \
      VFG4SNXD VFG50T9D VEGVPHMZ VEGVMATZ
    do
        DEV="/dev/disk/by-id/ata-HSH721414ALN6M0_${SERIAL}"

        echo
        echo "===== $SERIAL ====="

        timeout 30 smartctl -a "$DEV" 2>&1
    done
} >> "$LOG"
