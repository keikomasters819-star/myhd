#!/bin/bash

ROOT=/mnt/pve/nvme_vmstore/config-backup/auto
TS=$(date '+%Y%m%d-%H%M%S')
DIR="$ROOT/$TS"

mkdir -p "$DIR"
mkdir -p "$DIR/monitoring"

cp -a /etc/pve/qemu-server/100.conf "$DIR/"
cp -a /etc/pve/storage.cfg "$DIR/"
cp -a /etc/fstab "$DIR/"
cp -a /etc/mdadm/mdadm.conf "$DIR/"
cp -a /etc/modprobe.d/dm-zoned-custom.conf "$DIR/"
cp -a /usr/local/sbin/dmz-restore.sh "$DIR/"
cp -a /etc/systemd/system/dmz-restore.service "$DIR/"
cp -a /etc/systemd/system/pve-guests.service.d/dmz.conf "$DIR/"

qm config 100 > "$DIR/qm100.txt"
cat /proc/mdstat > "$DIR/mdstat.txt"
mdadm --detail --scan > "$DIR/mdadm-scan.txt"
vgs > "$DIR/vgs.txt"
lvs -a -o +devices > "$DIR/lvs.txt"
dmsetup ls --target zoned > "$DIR/dmz-list.txt"


cp -a /usr/local/sbin/dmz-*.sh "$DIR/monitoring/" 2>/dev/null || true
cp -a /usr/local/sbin/dmz-status "$DIR/monitoring/" 2>/dev/null || true
cp -a /usr/local/sbin/dmz-trend "$DIR/monitoring/" 2>/dev/null || true

cp -a /etc/systemd/system/dmz-* \
"$DIR/monitoring/" 2>/dev/null || true

cp -a /etc/logrotate.d/dmz-monitor \
"$DIR/monitoring/" 2>/dev/null || true

sha256sum "$DIR/monitoring/"* \
> "$DIR/monitoring/SHA256SUMS" 2>/dev/null || true
