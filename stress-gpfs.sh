#!/bin/sh

CPUS=${1:-8}
TIMEOUT_SECS=${2:-300}
DISK_SEQ_WORKERS=${3:-4}
DISK_META_WORKERS=${4:-4}
DISK_DIR="/tmp/stress"
BLOCK_SIZE="1M"
FILE_SIZE_BLOCKS=512  # 512MB per file per iteration

worker_pids=""

cleanup(){
    for pid in $worker_pids; do
        kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    rm -rf "$DISK_DIR"
}

trap cleanup EXIT INT TERM

mkdir -p "$DISK_DIR"

# --- CPU stress workers ---
i=0
while [ "$i" -lt "$CPUS" ]; do
    ( while :; do :; done ) &
    worker_pids="$worker_pids $!"
    i=$((i + 1))
done

# --- Sequential write throughput workers ---
# /dev/zero to avoid urandom CPU bottleneck; fdatasync to bypass page cache
j=0
while [ "$j" -lt "$DISK_SEQ_WORKERS" ]; do
    (
        while :; do
            dd if=/dev/zero of="$DISK_DIR/seq_${j}" bs="$BLOCK_SIZE" count="$FILE_SIZE_BLOCKS" conv=fdatasync 2>/dev/null
            # read it back to stress read path too
            dd if="$DISK_DIR/seq_${j}" of=/dev/null bs="$BLOCK_SIZE" 2>/dev/null
        done
    ) &
    worker_pids="$worker_pids $!"
    j=$((j + 1))
done

# --- Small random I/O workers ---
# Hammers GPFS with small random writes across many offsets in a single file
k=0
while [ "$k" -lt "$DISK_SEQ_WORKERS" ]; do
    (
        file="$DISK_DIR/rand_${k}"
        # pre-create a 128MB sparse file
        dd if=/dev/zero of="$file" bs=1 count=0 seek=134217728 2>/dev/null
        while :; do
            # random 4K writes at random offsets within the file
            offset=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 32768) * 4096 ))
            dd if=/dev/zero of="$file" bs=4096 count=1 seek=$((offset / 4096)) conv=notrunc,fdatasync 2>/dev/null
        done
    ) &
    worker_pids="$worker_pids $!"
    k=$((k + 1))
done

# --- Metadata storm workers ---
# create/stat/delete many small files — hammers GPFS token manager and distributed locks
m=0
while [ "$m" -lt "$DISK_META_WORKERS" ]; do
    (
        meta_dir="$DISK_DIR/meta_${m}"
        mkdir -p "$meta_dir"
        seq=0
        while :; do
            # create batch of small files
            batch=0
            while [ "$batch" -lt 200 ]; do
                printf 'x' > "$meta_dir/f_${seq}_${batch}"
                batch=$((batch + 1))
            done
            # stat them all
            ls -la "$meta_dir/" > /dev/null 2>&1
            stat "$meta_dir"/f_${seq}_* > /dev/null 2>&1
            # delete them all
            rm -f "$meta_dir"/f_${seq}_*
            seq=$((seq + 1))
        done
    ) &
    worker_pids="$worker_pids $!"
    m=$((m + 1))
done

total_workers=$((CPUS + DISK_SEQ_WORKERS + DISK_SEQ_WORKERS + DISK_META_WORKERS))
printf '=== stress test config ===\n'
printf 'cpu workers:        %d\n' "$CPUS"
printf 'seq write workers:  %d (512MB /dev/zero + readback, fdatasync)\n' "$DISK_SEQ_WORKERS"
printf 'rand I/O workers:   %d (4K random writes, fdatasync)\n' "$DISK_SEQ_WORKERS"
printf 'metadata workers:   %d (200-file create/stat/delete loops)\n' "$DISK_META_WORKERS"
printf 'target dir:         %s\n' "$DISK_DIR"
printf 'duration:           %d secs\n' "$TIMEOUT_SECS"
printf 'total PIDs:         %s\n' "$worker_pids"
printf '=========================\n'

start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$TIMEOUT_SECS" ]; do
    sleep 1
done

printf 'done\n'
