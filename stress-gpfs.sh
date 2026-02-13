#!/bin/sh

CPUS=${1:-8}
TIMEOUT_SECS=${2:-300}
GPFS_WORKERS=${3:-4}
MEM_MB=${4:-4096}
DISK_DIR="/tmp/stress"

worker_pids=""

cleanup(){
    for pid in $worker_pids; do
        kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    rm -rf "$DISK_DIR"
}

trap cleanup EXIT INT TERM

mkdir -p "$DISK_DIR/shared" "$DISK_DIR/meta" "$DISK_DIR/links"

# --- CPU stress workers ---
i=0
while [ "$i" -lt "$CPUS" ]; do
    ( while :; do :; done ) &
    worker_pids="$worker_pids $!"
    i=$((i + 1))
done

# --- Memory drain ---
if command -v python3 > /dev/null 2>&1; then
    mem_bytes=$((MEM_MB * 1024 * 1024))
    python3 -c "
x = b'\x00' * ${mem_bytes}
import time; time.sleep(${TIMEOUT_SECS} + 10)
" &
    worker_pids="$worker_pids $!"
    mem_status="python3 (${MEM_MB}MB allocated)"
else
    printf 'WARNING: python3 not found, skipping memory stress\n'
    mem_status="skipped (no python3)"
fi

# =============================================================
# GPFS CPU stress — all designed to maximize token churn
# =============================================================

# --- Shared file contention ---
# Multiple workers do random 4K writes + fdatasync to the SAME file
# Forces constant token revocation/grant between processes
shared_file="$DISK_DIR/shared/contested"
dd if=/dev/zero of="$shared_file" bs=1 count=0 seek=134217728 2>/dev/null
j=0
while [ "$j" -lt "$GPFS_WORKERS" ]; do
    (
        while :; do
            offset=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 32768) * 4096 ))
            dd if=/dev/zero of="$shared_file" bs=4096 count=1 seek=$((offset / 4096)) conv=notrunc,fdatasync 2>/dev/null
        done
    ) &
    worker_pids="$worker_pids $!"
    j=$((j + 1))
done

# --- Shared file readers competing with writers ---
# Read tokens vs write tokens on the same file = revocation storm
r=0
while [ "$r" -lt "$GPFS_WORKERS" ]; do
    (
        while :; do
            dd if="$shared_file" of=/dev/null bs=4096 count=1 skip=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 32768) )) 2>/dev/null
        done
    ) &
    worker_pids="$worker_pids $!"
    r=$((r + 1))
done

# --- Attribute churn ---
# chmod/chown/touch in tight loops on shared files
# Each op requires metadata token grant + journal write
a=0
while [ "$a" -lt "$GPFS_WORKERS" ]; do
    (
        target="$DISK_DIR/shared/attrfile_${a}"
        printf 'x' > "$target"
        mode=0
        while :; do
            if [ "$mode" -eq 0 ]; then
                chmod 644 "$target"
                mode=1
            else
                chmod 755 "$target"
                mode=0
            fi
            touch "$target"
        done
    ) &
    worker_pids="$worker_pids $!"
    a=$((a + 1))
done

# --- Cross-worker attribute contention ---
# All workers chmod/touch the SAME file = metadata token fight
(
    target="$DISK_DIR/shared/contested_attr"
    printf 'x' > "$target"
    while :; do chmod 644 "$target"; touch "$target"; chmod 755 "$target"; done
) &
worker_pids="$worker_pids $!"
(
    target="$DISK_DIR/shared/contested_attr"
    while :; do chmod 600 "$target"; touch "$target"; chmod 777 "$target"; done
) &
worker_pids="$worker_pids $!"

# --- Metadata storm with deep directories ---
# Create files WITHOUT deleting — let directory grow huge, then stat/ls all
# Directory block scanning + large readdir = CPU intensive
m=0
while [ "$m" -lt "$GPFS_WORKERS" ]; do
    (
        meta_dir="$DISK_DIR/meta/worker_${m}"
        mkdir -p "$meta_dir"
        seq=0
        while :; do
            # create batch
            batch=0
            while [ "$batch" -lt 500 ]; do
                printf 'x' > "$meta_dir/f_${seq}_${batch}"
                batch=$((batch + 1))
            done
            seq=$((seq + 1))
            # stat and list the growing directory every batch
            ls -la "$meta_dir/" > /dev/null 2>&1
            stat "$meta_dir"/f_${seq}_* > /dev/null 2>&1
            # only delete once dir gets very large to keep pressure sustained
            count=$(ls -1 "$meta_dir" 2>/dev/null | wc -l)
            if [ "$count" -gt 10000 ]; then
                rm -f "$meta_dir"/f_*
            fi
        done
    ) &
    worker_pids="$worker_pids $!"
    m=$((m + 1))
done

# --- Hardlink/symlink churn ---
# link creation/deletion is metadata-heavy, each requires token grants
l=0
while [ "$l" -lt "$GPFS_WORKERS" ]; do
    (
        link_dir="$DISK_DIR/links/worker_${l}"
        mkdir -p "$link_dir"
        source_file="$link_dir/source"
        printf 'x' > "$source_file"
        while :; do
            n=0
            while [ "$n" -lt 200 ]; do
                ln "$source_file" "$link_dir/hl_${n}" 2>/dev/null
                ln -s "$source_file" "$link_dir/sl_${n}" 2>/dev/null
                n=$((n + 1))
            done
            stat "$link_dir"/hl_* > /dev/null 2>&1
            stat "$link_dir"/sl_* > /dev/null 2>&1
            rm -f "$link_dir"/hl_* "$link_dir"/sl_*
        done
    ) &
    worker_pids="$worker_pids $!"
    l=$((l + 1))
done

# --- Sequential write (reduced — kept for some I/O throughput) ---
(
    while :; do
        dd if=/dev/zero of="$DISK_DIR/seq_bulk" bs=1M count=256 conv=fdatasync 2>/dev/null
    done
) &
worker_pids="$worker_pids $!"

# =============================================================

contention_workers=$((GPFS_WORKERS * 2))
attr_workers=$((GPFS_WORKERS + 2))
printf '=== GPFS CPU stress test config ===\n'
printf 'cpu workers:           %d\n' "$CPUS"
printf 'memory drain:          %s\n' "$mem_status"
printf 'shared file writers:   %d (4K random fdatasync, same file)\n' "$GPFS_WORKERS"
printf 'shared file readers:   %d (4K random reads, same file)\n' "$GPFS_WORKERS"
printf 'attribute churn:       %d (chmod/touch loops) + 2 contested\n' "$GPFS_WORKERS"
printf 'metadata storm:        %d (500-file batches, deep dirs, stat/ls)\n' "$GPFS_WORKERS"
printf 'hardlink/symlink:      %d (200 link create/stat/delete loops)\n' "$GPFS_WORKERS"
printf 'sequential write:      1 (256MB bulk writes)\n'
printf 'target dir:            %s\n' "$DISK_DIR"
printf 'duration:              %d secs\n' "$TIMEOUT_SECS"
printf '===================================\n'

start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$TIMEOUT_SECS" ]; do
    sleep 1
done

printf 'done\n'
