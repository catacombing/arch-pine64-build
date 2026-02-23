#!/bin/sh

# Build client for https://github.com/catacombing/isotopia job control server.

api="https://catacombing.org/isotopia"

if [[ $# -lt 1 ]]; then
    echo "Usage: bench.sh <UPLOAD_SECRET>"
    exit 1
fi
upload_secret="$1"

while true; do
    # Wait after each attempt.
    sleep ${interval:-0}
    interval=10

    # Get the next pending job.
    echo "[$(date +%H:%M:%S)] Checking for pending jobs…"
    job=$(curl -sf "$api/requests/pending" | jq -c '.[0]') || exit
    if [[ "$job" == "null" ]]; then
        continue;
    fi

    # Get job attributes.
    packages=$(echo "$job" | jq -r '.packages')
    device=$(echo "$job" | jq -r '.device')
    md5sum=$(echo "$job" | jq -r '.md5sum')
    echo "Found new pending job: $md5sum ($device)"

    # Notify jobserver we'd like to build this job.
    #
    # This will fail when a racing condition caused a different builder to pick
    # up the same job.
    curl -fX PUT --json '"building"' "$api/requests/$device/$md5sum/status" || continue

    # Build the image.
    if [ "$device" == "fairphone-fp5" ]; then
        echo "Starting FP5 build of $md5sum…"
        ./build_fp5.sh -a aarch64 -d "$device" -p "$packages" || continue
    else
        echo "Starting build of $md5sum…"
        ./build.sh -a aarch64 -d "$device" -p "$packages" || continue
    fi
    echo "Finished build of $md5sum"

    alarm_md5sum=$(md5sum ./build/ArchLinuxARM* | awk '{print $1}')
    if [ "$device" == "fairphone-fp5" ]; then
        filename="alarm-$device-$alarm_md5sum-$md5sum.tar"
    else
        filename="alarm-$device-$alarm_md5sum-$md5sum.img.xz"
    fi

    # Upload the built image.
    if [ -f "./build/$filename" ]; then
        curl -fX POST \
            -H "Authorization: Bearer $1" \
            -F filename=@"./build/$filename" \
            "$api/requests/$device/$md5sum/$alarm_md5sum/image" \
            || continue
        echo "Finished upload of $md5sum"
    else
        echo "Built image $filename does not exist"
    fi
done
