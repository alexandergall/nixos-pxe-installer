source $stdenv/setup

umask 022

sources_=($sources)
targets_=($targets)

objects=($objects)
symlinks=($symlinks)

mkdir $out
nfsroot=$out/nfsroot.tar
tar -cf $nfsroot -T /dev/null

stripSlash() {
    res="$1"
    if test "${res:0:1}" = /; then res=${res:1}; fi
}

addPath() {
    source=$1
    target=$2
    owner=$3
    group=$4
    cd=
    echo -n "adding path $source"
    if [[ "$source" =~ ^\/ ]]; then
	cd="-C /"
	stripSlash $source; source=$res
    fi
    transform=
    if [ -n "$target" ]; then
	echo " as $target"
	stripSlash $target; target=$res
	transform=--transform="s|$source|$target|"
    else
	if [ -h "$source" ]; then
	    echo " -> $(readlink $source)"
	else
	    echo
	fi
    fi
    [ -n "$owner" ] && owner=--owner=$owner
    [ -n "$group" ] && group=--group=$group
    tar $cd $owner $group $transform -rf $nfsroot $source
}

echo "creating NFS root filesystem"
# Add the individual files.
for ((i = 0; i < ${#targets_[@]}; i++)); do
    addPath ${sources_[$i]} ${targets_[$i]}
done

# Add the closures of the top-level store objects.
storePaths=$(perl $pathsFromGraph closure-*)
for i in $storePaths; do
    addPath $i
done


# Also include a manifest of the closures in a format suitable for
# nix-store --load-db.
if [ -n "$object" ]; then
    printRegistration=1 perl $pathsFromGraph closure-* > nix-path-registration
    addPath nix-path-registration nix/store/nix-path-registration
fi

# Add symlinks to the top-level store objects.
for ((n = 0; n < ${#objects[*]}; n++)); do
    object=${objects[$n]}
    symlink=${symlinks[$n]}
    if test "$symlink" != "none"; then
	stripSlash $symlink; symlink=$res
        mkdir -p $(dirname ./$symlink)
        ln -s $object ./$symlink
	addPath $symlink
    fi
done

for d in dev etc proc sys union unionfs installer; do
    mkdir $d
    addPath $d /$d root root
done

echo "compressing tar archive"
xz -v $nfsroot
