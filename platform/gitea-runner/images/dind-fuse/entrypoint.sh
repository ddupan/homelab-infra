#!/bin/sh
set -eu

# /dev belongs to the Kata guest. A privileged dockerd container can create
# this standard FUSE node without exposing the PVE host's /dev/fuse to the LXC.
if [ ! -e /dev/fuse ]; then
    mknod /dev/fuse c 10 229
fi
chmod 0666 /dev/fuse

# kind's nested kubelet opens /dev/kmsg. This node belongs to the Kata guest;
# exposing it to a kind node does not expose the LXC or PVE host kernel log.
if [ ! -e /dev/kmsg ]; then
    mknod /dev/kmsg c 1 11
fi
chmod 0600 /dev/kmsg

storage_driver=fuse-overlayfs

# kind's kubelet/cAdvisor cannot map a virtiofs-backed fuse-overlayfs root to a
# block device. When requested, create an ext4 filesystem on a guest-local loop
# device. The backing file, loop device and filesystem all die with the Kata VM.
if [ -n "${DIND_LOOPBACK_SIZE:-}" ]; then
    [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237
    i=0
    while [ "$i" -lt 8 ]; do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i"
        i=$((i + 1))
    done

    backing_file="${DIND_LOOPBACK_FILE:-/var/lib/docker-loopback.img}"
    truncate -s "$DIND_LOOPBACK_SIZE" "$backing_file"
    # Alpine's BusyBox losetup supports -f, but not util-linux's
    # --find/--show long options.
    loop_device="$(losetup -f)"
    losetup "$loop_device" "$backing_file"
    mkfs.ext4 -q -F -m 0 "$loop_device"
    mount "$loop_device" /var/lib/docker
    storage_driver=overlay2
fi

exec dockerd-entrypoint.sh --storage-driver="$storage_driver" "$@"
