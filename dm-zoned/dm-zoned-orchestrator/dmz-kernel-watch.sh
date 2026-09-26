#!/bin/bash

ROOT=/mnt/pve/nvme_vmstore/dmz-logs/kernel
LOG="$ROOT/kernel-errors.log"

mkdir -p "$ROOT"

journalctl -k -f -n 0 -o short-iso |
grep --line-buffered -Ei \
'dm.?zoned|I/O error|buffer I/O|blk_update_request|timeout|reset|abort|nvme.*error|ata.*error|EXT4-fs error|device-mapper.*error|md.*fault|medium error' |
while IFS= read -r LINE; do
    echo "$LINE" >> "$LOG"
done
