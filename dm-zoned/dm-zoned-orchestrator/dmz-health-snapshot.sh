#!/bin/bash

ROOT=/mnt/pve/nvme_vmstore/dmz-logs/health
LOG="$ROOT/health.csv"

mkdir -p "$ROOT"

if [ ! -s "$LOG" ]; then
    echo "timestamp,dmz_count,generic_count,vmstore_mount,pve_storage,vm100,dmz_service,vmstore_use_pct,cacheA_active,cacheB_active,vmstore_active" > "$LOG"
fi

DMZ=$(dmsetup ls --target zoned 2>/dev/null |
      awk '$1 ~ /^dmz_D/{n++} END{print n+0}')

GEN=$(dmsetup ls --target zoned 2>/dev/null |
      awk '$1 ~ /^dmz-dm-/{n++} END{print n+0}')

findmnt -n /mnt/pve/nvme_vmstore >/dev/null 2>&1 &&
MOUNT=1 || MOUNT=0

STORAGE=$(pvesm status 2>/dev/null |
          awk '$1=="nvme-vmstore"{print $3}')

VM=$(qm status 100 2>/dev/null | awk '{print $2}')

SERVICE=$(systemctl is-active dmz-restore.service 2>/dev/null)

USE=$(df -P /mnt/pve/nvme_vmstore 2>/dev/null |
      awk 'NR==2 {gsub("%","",$5);print $5}')

mdactive() {
    mdadm --detail "$1" 2>/dev/null |
      awk -F: '/Active Devices/ {gsub(/ /,"",$2); print $2}'
}

A=$(mdactive /dev/md/dmz_cache_A)
B=$(mdactive /dev/md/dmz_cache_B)
V=$(mdactive /dev/md/vm_store)

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%F %T')" \
    "$DMZ" "$GEN" "$MOUNT" "$STORAGE" \
    "$VM" "$SERVICE" "${USE:-0}" \
    "${A:-0}" "${B:-0}" "${V:-0}" >> "$LOG"

if [ "$DMZ" -ne 12 ] ||
   [ "$GEN" -ne 0 ] ||
   [ "$MOUNT" -ne 1 ] ||
   [ "$SERVICE" != "active" ]; then

    logger -p daemon.err -t dmz-health \
      "abnormal dmz=$DMZ generic=$GEN mount=$MOUNT service=$SERVICE"
fi
