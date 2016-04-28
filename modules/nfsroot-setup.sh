#! @shell@

echo
echo -e "\e[40;1;32m<<< NixOS NFS root file system setup >>>\e[0m"
echo


# Set the PATH.
setPath() {
    local dirs="$1"
    export PATH=/empty
    for i in $dirs; do
        PATH=$PATH:$i/bin
        if test -e $i/sbin; then
            PATH=$PATH:$i/sbin
        fi
    done
}

setPath "@path@"

## When we get here, the root fs is mounted read-only
## via NFS.  It contains the mount points /dev, /proc,
## /sys, /union and /unionfs.

## The final r/w root fs will be here
targetRoot=/union

mount -n -t tmpfs none $targetRoot
mount -n -t tmpfs none /unionfs
mkdir /unionfs/root /unionfs/rw
mount --bind / /unionfs/root
## Combine the r/o NFS root with an empty RAM disk and
## mount it on the target root mount point
unionfs -o cow,nonempty,dev,allow_other,use_ino,max_files=32768,chroot=/unionfs /rw=rw:/root=ro $targetRoot
cd $targetRoot
mkdir oldroot
## Mathe the unified fs the root
pivot_root . oldroot
## Mount some essential stuff in the new root
mount --move /oldroot/dev dev
mount -t proc proc proc
mount -t sysfs sysfs sys

## Execute the NixOS installer from within the
## fully functional root fs
exec chroot . @installer@
