#! /bin/bash -e
set -o pipefail
STEPS="setupoe,initramfs,stubinitramfs,dom0,uivm,ndvm,syncvm,sysroot,installer,installer2,syncui,source,sdk,license,sourceinfo,ship"

# Additional steps:

# copy: Copies the build output to a web/pxe server. See do_copy() for more details.
# Requires a valid BUILD_RSYNC_DESTINATION in .config

# extra_pkgs: Builds a bunch of extra OpenEmbedded packages, that will be installable separately.
# Combined with packages_tree, this allows easy debugging on the target.
# For example, on an OpenXT machine: # rw ; opkg update ; opkg install gdb surfman-dbg; ro

# packages_tree: Adds the built packages to an OpenEmbedded repository pool.
# Packages tree can use hardlinks to save disk space, if $SYNC_CACHE_OE/oe-archives is populated
# Requires a valid SYNC_CACHE_OE, BUILD_RSYNC_DESTINATION and NETBOOT_HTTP_URL in .config

TOPDIR=`pwd`
OUTPUT_DIR="$TOPDIR/build-output"
CMD="$0"
CMD_DIR=`dirname "$CMD"`
NAME=""
ENV=0
VERBOSE=0
SOURCE=0
BUILD_USER="`whoami`"
OE_BB_THREADS="8"
CACHE_DIR="$TOPDIR/build/cache"
OE_BUILD_CACHE="$TOPDIR/build"
BRANCH=master
BUILD_UID=`id -u`
export BUILD_UID

# TODO: move some of the above definitions into common-config

source ${CMD_DIR}/common-config
source ${CMD_DIR}/build_helpers.sh

create_ramdisk()
{
        local path="$1"
        local type="$2"

        if [ $type -eq 0 ]; then
                return
        fi

        mkdir -p "$path"
        if [ $type -eq 1 ]; then
                #tmpfs ramfs

                local fstype="`df -T "$path" | tail -n1 | awk '{print $2}'`"

                if [ "$fstype" != "tmpfs" ]; then
                        echo "Create ramfs ($path)"
                        sudo mount -t tmpfs -o size=20G tmpfs "$path"
                fi
        fi

        if [ $type -eq 2 ]; then
                #ext2 on ramdisk

                local dev="`df -T "$path" | tail -n1 | awk '{print $1}'`"

                if [ "$dev" != "/dev/ram0" ]; then

                        echo "Create ram disk on ($path)"

                        dev="/dev/ram0"

                        sudo modprobe brd rd_size=$[20 * 1024 * 1024]
                        sudo mke2fs -b 4096 "$dev"
                        sudo tune2fs -m 0 -i 0 -c 0 "$dev"
                        sudo mount "$dev" "$path"
                        sudo chmod 1777 "$path"
                fi
        fi


}

do_make()
{
        local rule="$1"
        local output="$2"

        (
        set +x
         < /dev/null make $rule 2>&1 | \
                while read l; do echo "$(date "+[%H:%M:%S.%N]"): $l"; done | tee "$output";
        )
}

do_sim()
{
        local path="$1"
        local dom0rootfs="$OUTPUT_DIR/$NAME/raw/dom0-rootfs.i686.ext3.gz"

        mkdir -p "$path"
        pushd "$path"

        git_clone "xc-test" "$OPENXT_GIT_PROTOCOL://$OPENXT_GIT_MIRROR/xc-test.git" "$BRANCH" "$ALLOW_SWITCH_BRANCH_FAIL"

        pushd "xc-test/xc-sim"

        do_make "BUILDNO=${ID} ID=${ID} ROOTFS=${dom0rootfs} xc-sim" "build.log"

        popd
        popd
}

do_oe_log()
{
    (
        set +x
        while read l; do echo "`date "+[%H:%M:%S.%N]"`: $l"; done
    )
}

do_oe_setup()
{
        local path="$1"
        local branch="$BRANCH"

        mkdir -p "$path"
        pushd "$path" > /dev/null

        echo "*:$BRANCH" > "manifest"

        if [ ! -f "local.settings" ]; then
                cat > local.settings <<EOF
META_SELINUX_REPO=$OPENXT_GIT_PROTOCOL://$OPENXT_GIT_MIRROR/meta-selinux.git
EXTRA_REPO=$OPENXT_GIT_PROTOCOL://$OPENXT_GIT_MIRROR/xenclient-oe-extra.git
EXTRA_DIR=extra
EXTRA_TAG="$BRANCH"
XENCLIENT_REPO=$OPENXT_GIT_PROTOCOL://$OPENXT_GIT_MIRROR/xenclient-oe.git
XENCLIENT_TAG="$BRANCH"
EOF

                if [ "$OE_GIT_MIRROR" ] ; then
                        cat >> local.settings <<EOF
BITBAKE_REPO=$OE_GIT_MIRROR/bitbake.git
OE_CORE_REPO=$OE_GIT_MIRROR/openembedded-core.git
META_OE_REPO=$OE_GIT_MIRROR/meta-openembedded.git
META_JAVA_REPO=$OE_GIT_MIRROR/meta-java.git
EOF
                fi
        fi

        if [ -z "$REPO_PROD_CACERT" ] ; then
                echo "Error: REPO_PROD_CACERT must be set in .config." >&2
                exit 1
        fi

        if [ -z "$REPO_DEV_CACERT" ] ; then
                echo "Error: REPO_DEV_CACERT must be set in .config." >&2
                exit 1
        fi

        local REPO_PROD_CACERT_PATH="$(resolve_path "$TOPDIR" "$REPO_PROD_CACERT")"
        local REPO_DEV_CACERT_PATH="$(resolve_path "$TOPDIR" "$REPO_DEV_CACERT")"

        check_repo_signing_file "$REPO_PROD_CACERT_PATH" \
                "Production repository-signing CA certificate"
        check_repo_signing_file "$REPO_DEV_CACERT_PATH" \
                "Development repository-signing CA certificate"

        [ "x$ORIGIN_BRANCH" != "x" ] && branch="$ORIGIN_BRANCH"

        oedl="$OE_BUILD_CACHE/downloads"
        [ "x$OE_BUILD_CACHE_DL" != "x" ] && oedl="$OE_BUILD_CACHE_DL"

        EXTRA_CLASSES=""
        [ "x$INHIBIT_RMWORK" == "x" ] && EXTRA_CLASSES="rm_work $EXTRA_CLASSES"

        if [ ! -e conf ]; then
            mkdir -p conf
        fi

        if [ ! -f "conf/local.conf" ]; then
                cp conf/local.conf-dist conf/local.conf

                if [ ! -z "${OE_TARBALL_MIRROR}" ] ; then
                cat >> conf/local.conf <<EOF
# Tarball mirror
PREMIRRORS = "(ftp|https?)$://.*/.*/ ${OE_TARBALL_MIRROR}"
EOF
                fi
                cat >> conf/local.conf <<EOF

# Distribution feed
XENCLIENT_PACKAGE_FEED_URI="${NETBOOT_HTTP_URL}/${ORIGIN_BRANCH}/${NAME}/packages/ipk"

# Local generated configuration for build $ID
INHERIT += "$EXTRA_CLASSES"
SSTATE_DIR = "$OE_BUILD_CACHE/sstate-cache/$branch"

DL_DIR = "$oedl"
export CCACHE_DIR = "${CACHE_DIR}"
CCACHE_TARGET_DIR="$CACHE_DIR"

PARALLEL_MAKE = "-j 8"
BB_NUMBER_THREADS = "$OE_BB_THREADS"
OPENXT_MIRROR="$OPENXT_MIRROR"
OPENXT_GIT_MIRROR="$OPENXT_GIT_MIRROR"
OPENXT_GIT_PROTOCOL="$OPENXT_GIT_PROTOCOL"
OPENXT_BRANCH="$ORIGIN_BRANCH"
OPENXT_TAG="$BRANCH"

require conf/xenclient-extra.conf
EOF

                if [ "x$ID" != "x" ]; then
                    echo "XENCLIENT_BUILD = \"$ID\"" >> conf/local.conf
                else
                    echo "XENCLIENT_BUILD = \"$NAME\"" >> conf/local.conf
                fi

                cat >> conf/local.conf <<EOF
XENCLIENT_BUILD_DATE = "`date +'%T %D'`"
XENCLIENT_BUILD_BRANCH = "${ORIGIN_BRANCH}"
XENCLIENT_VERSION = "$VERSION"
XENCLIENT_RELEASE = "$RELEASE"
XENCLIENT_TOOLS = "$XENCLIENT_TOOLS"

# dir for generated deb packages
XCT_DEB_PKGS_DIR := "${OE_BUILD_CACHE}/xct_deb_packages"

# xen version and source
XEN_VERSION="${XEN_VERSION}"
XEN_SRC_URI="${XEN_SRC_URI}"
XEN_SRC_MD5SUM="${XEN_SRC_MD5SUM}"
XEN_SRC_SHA256SUM="${XEN_SRC_SHA256SUM}"

EOF

                cat >> conf/local.conf <<EOF
# Production and development repository-signing CA certificates
REPO_PROD_CACERT="$REPO_PROD_CACERT_PATH"
REPO_DEV_CACERT="$REPO_DEV_CACERT_PATH"

EOF

                if [ $SOURCE -eq 1 ]
                then
                    cat >> conf/local.conf <<EOF 

XENCLIENT_BUILD_SRC_PACKAGES = "1"
XENCLIENT_COLLECT_SRC_INFO = "1"
EOF
                fi
                if [ "x$FREEZE_URIS" = "xyes" ]
                then
                    cat >> conf/local.conf <<EOF 

INHERIT += "freezer"
EOF
                fi
        fi

        if [ $VERBOSE -eq 1 ]
        then
            echo "Generated config is:"
            cat conf/local.conf
        fi

	if [ $VERBOSE -eq 1 ]
	then 
            OPTS="-v"
	else
	    OPTS=""
	fi

	${TOPDIR}/setup_build $OPTS

        popd > /dev/null
}

check_repo_signing_file()
{
    local FILE="$1"
    local DESC="$2"

    # TODO: Add script to generate set of production/development CA
    # certificates and signing certificates and refer to it in this
    # error message.
    if [ ! -e "$FILE" ] ; then
        cat <<EOF >&2
Error: $DESC '$FILE' not found.
EOF
        false
    fi
}

do_oe_check_cpp()
{
        local path="$1"

        pushd "$path"

        cat <<- EOF > fish.cpp
#include <stdio.h>
int main(int argc, char *argv[]) { printf("fish\n"); }
EOF

        export MACHINE="xenclient-dom0"
         build/cross/i686core2/bin/i686-angstrom-linux-gcc -c -o fish.o fish.cpp | do_oe_log
        rm -rf fish.o fish.cpp
        popd
}

do_oe()
{
        local path="$1"
        local machine="$2"
        local image="$3"
        local log_path="${OUTPUT_DIR}/${NAME}/logs"
        local dont_get_log="$4"

        pushd "$path"
        export MACHINE="$machine"
        if [ "x$FREEZE_URIS" = "xyes" ]; then
            echo "Running URI freezer"
             < /dev/null ./bb --disable-wrapper -c freezeall "$image" | do_oe_log
            # kill the cache
            rm -fr tmp-eglibc/cache
        fi
        if [ $VERBOSE -eq 1 ] 
        then
            BBFLAGS="-v"
	else
	    BBFLAGS=""
	fi
	echo "STARTING OE BUILD $image $machine, started at" `date -u +'%H:%M:%S UTC'`

         < /dev/null ./bb $BBFLAGS "$image" | do_oe_log
        popd

        if [ -z "${dont_get_log}" -a -z "${NEVER_GET_LOG}" ] ; then
            mkdir -p "${log_path}"
            echo "Collecting build logs..." | do_oe_log
            find $path/tmp-eglibc/work/*/*/temp -name "log.do_*" | tar -cjf "${log_path}/$machine-$image.tar.bz2" --files-from=- | do_oe_log
            echo "Done" | do_oe_log
            echo "Collecting sigdata..." | do_oe_log
            find "$path/tmp-eglibc/stamps" -name "*.sigdata.*" | tar -cjf "${log_path}/sigdata-$machine-$image.tar.bz2" --files-from=- | do_oe_log
            echo "Done" | do_oe_log
            echo "Collecting buildstats..." | do_oe_log
            tar -cjf "${log_path}/buildstats-$machine-$image.tar.bz2" "$path/tmp-eglibc/buildstats" | do_oe_log
            echo "Done" | do_oe_log
        fi
}

do_oe_copy()
{
        local path="$1"
        local name="$2"
        local image="$3"
        local machine="$4"
        local binaries="tmp-eglibc/deploy/images"
        local t=""
        local unhappy=1
        pushd "$path"
        # Copy OE
        mkdir -p "$OUTPUT_DIR/$NAME/raw"
        for t in cpio cpio.gz cpio.bz2 \
            tar tar.gz tar.bz2 \
            ext3 ext3.gz ext3.bz2 \
            ext3.vhd ext3.vhd.gz ext3.vhd.bz2 \
            xc.ext3 xc.ext3.gz xc.ext3.bz2 \
            xc.ext3.vhd xc.ext3.vhd.gz xc.ext3.vhd.bz2 \
            xc.ext3.bvhd xc.ext3.bvhd.gz xc.ext3.bvhd.bz2
	do
            if [ -f "$binaries/$image-image-$machine.$t" ]; then
                echo "$name image type: $t"
                cp "$binaries/$image-image-$machine.$t" "$OUTPUT_DIR/$NAME/raw/$name-rootfs.i686.$t"
                unhappy=0
            fi
        done
        if [ "$unhappy" -eq "1" ]; then
            echo "$name image not found" 1>&2
            popd
            exit 1
        fi
        popd
}

do_oe_extra_pkgs()
{
        local path="$1"

        do_oe "$path" "xenclient-dom0" "task-xenclient-extra" "true"
        do_oe "$path" "xenclient-dom0" "package-index"
}

do_oe_uivm_copy()
{
        local path="$1"
        do_oe_copy "$path" "uivm" "xenclient-uivm" "xenclient-uivm"
}

do_oe_uivm()
{
        local path="$1"
        do_oe "$path" "xenclient-uivm" "xenclient-uivm-image"
        do_oe_uivm_copy $path
}

do_oe_ndvm_copy()
{
        local path="$1"
        do_oe_copy "$path" "ndvm" "xenclient-ndvm" "xenclient-ndvm"
}

do_oe_ndvm()
{
        local path="$1"
        do_oe "$path" "xenclient-ndvm" "xenclient-ndvm-image"
        do_oe_ndvm_copy $path
}

do_oe_nilfvm_copy()
{
        local path="$1"
        do_oe_copy "$path" "nilfvm" "xenclient-nilfvm" "xenclient-nilfvm"

        local binaries="tmp-eglibc/deploy/images"
        pushd "$path"
        cp "$binaries/service-nilfvm" "$OUTPUT_DIR/$NAME/raw/service-nilfvm"
        popd
}

do_oe_nilfvm()
{
        local path="$1"

        echo This step is now useless, everything we need should be built as part of the tools.
        return

        do_oe "$path" "xenclient-nilfvm" "xenclient-nilfvm-image"
        do_oe_nilfvm_copy $path
}

do_oe_syncvm_copy()
{
        local path="$1"
        do_oe_copy "$path" "syncvm" "xenclient-syncvm" "xenclient-syncvm"
}

do_oe_syncvm()
{
        local path="$1"
        do_oe "$path" "xenclient-syncvm" "xenclient-syncvm-image"
        do_oe_syncvm_copy $path
}

do_oe_syncui_copy()
{
        local path="$1"
        pushd "$path"
        mkdir -p "$OUTPUT_DIR/$NAME/raw"
        cp tmp-eglibc/deploy/tar/sync-wui-0+git*.tar.gz "$OUTPUT_DIR/$NAME/raw/sync-wui-${RELEASE}.tar.gz"
        cp tmp-eglibc/deploy/tar/sync-wui-sources-0+git*.tar.gz "$OUTPUT_DIR/$NAME/raw/sync-wui-sources-${RELEASE}.tar.gz"
        popd
}

do_oe_syncui()
{
        local path="$1"
        do_oe "$path" "xenclient-syncui" "sync-wui"
        do_oe_syncui_copy "$path"
}

do_oe_dom0_copy()
{
        local path="$1"
        do_oe_copy "$path" "dom0" "xenclient-dom0" "xenclient-dom0"
}

do_oe_dom0()
{
        local path="$1"
        do_oe "$path" "xenclient-dom0" "xenclient-dom0-image"
        do_oe_dom0_copy $path
}

do_oe_sysroot_copy()
{
        local path="$1"
        do_oe_copy "$path" "sysroot" "xenclient-sysroot" "xenclient-dom0"
}

do_oe_sysroot()
{
        local path="$1"
        do_oe "$path" "xenclient-dom0" "xenclient-sysroot-image"
        do_oe_sysroot_copy $path
}

do_oe_installer_copy()
{
        local path="$1"
        local binaries="tmp-eglibc/deploy/images"
        pushd "$path"

        mkdir -p "$OUTPUT_DIR/$NAME/raw/installer"
        # Copy installer
        cp "$binaries/xenclient-installer-image-xenclient-dom0.cpio.gz" "$OUTPUT_DIR/$NAME/raw/installer/rootfs.i686.cpio.gz"

        # Copy extra installer files
        rm -rf "$OUTPUT_DIR/$NAME/raw/installer/iso"
        cp -r "$binaries/xenclient-installer-image-xenclient-dom0/iso" \
                "$OUTPUT_DIR/$NAME/raw/installer/iso"
        rm -rf "$OUTPUT_DIR/$NAME/raw/installer/netboot"
        cp -r "$binaries/xenclient-installer-image-xenclient-dom0/netboot" \
                "$OUTPUT_DIR/$NAME/raw/installer/netboot"
        cp "$binaries/vmlinuz-xenclient-dom0.bin" \
                "$OUTPUT_DIR/$NAME/raw/installer/vmlinuz"
        cp "$binaries/xen.gz" \
                "$OUTPUT_DIR/$NAME/raw/installer/xen.gz"
        cp "$binaries/tboot.gz" \
                "$OUTPUT_DIR/$NAME/raw/installer/tboot.gz"
        cp "$binaries"/*.acm \
                "$OUTPUT_DIR/$NAME/raw/installer/"
        popd
}

do_oe_installer()
{
        local path="$1"

        do_oe "$path" "xenclient-dom0" "xenclient-installer-image"
        do_oe_installer_copy $path
}

do_oe_installer_part2_copy()
{
        local path="$1"
        local binaries="tmp-eglibc/deploy/images"
        pushd "$path"

        mkdir -p "$OUTPUT_DIR/$NAME/raw"

        cp "$binaries/xenclient-installer-part2-image-xenclient-dom0.tar.bz2" "$OUTPUT_DIR/$NAME/raw/control.tar.bz2"

        popd
}

do_oe_installer_part2()
{
        local path="$1"

        do_oe "$path" "xenclient-dom0" "xenclient-installer-part2-image"
        do_oe_installer_part2_copy $path
}

do_oe_source_shrink()
{
        local path="$1"
        local sum file last_sum last_file

        find "$path" -type f |
                xargs md5sum |
                sort |
                uniq -D -w32 |
                while read sum file
        do
                if [ "$sum" = "$last_sum" ]
                then
                        rm "$file"
                        ln "$last_file" "$file"
                fi

                last_sum="$sum"
                last_file="$file"
        done
}

do_oe_source_copy()
{
        local path="$1"
        local rootfs="tmp-eglibc/deploy/images/xenclient-source-image-xenclient-dom0.raw"
        pushd "$path" > /dev/null

        if [ "$SOURCE" -eq 0 ]
        then
                echo "Skipping 'source' step: '-S' option was not specified"
                return
        fi

        if [ ! -d "$rootfs" ] ; then
            echo "Source image not found ($rootfs)" >&2
            exit 1
        fi

        rm -rf "$OUTPUT_DIR/$NAME/raw/source"
        cp -Lr "$(pwd)/$rootfs" "$OUTPUT_DIR/$NAME/raw/source"

        do_oe_source_shrink "$OUTPUT_DIR/$NAME/raw/source"

        popd > /dev/null
}

do_oe_source()
{
        local path="$1"

        if [ "$SOURCE" -eq 0 ]
        then
                echo "Skipping 'source' step: '-S' option was not specified"
                return
        fi

        do_oe "$path" "xenclient-dom0" "xenclient-source-image"
        do_oe_source_copy "$path"
}

do_oe_packages_tree()
{
        local path="$1"
        local dest="$BUILD_RSYNC_DESTINATION/$ORIGIN_BRANCH/$NAME"

        # Create a separate package tree populated with symlinks for stuffs that didn't change
        # rsync seems to delegate non-remote operations to another program, ignoring --rsync-path
        # If the destination is not remote, we have to run the --rsync-path command hack manualy
        ( echo $BUILD_RSYNC_DESTINATION | grep ':' > /dev/null 2>&1) || mkdir -p "$dest"
        rsync -altvzr --exclude "morgue" --link-dest="$SYNC_CACHE_OE/oe-archive/"	\
            --rsync-path="mkdir -p \"$dest\" && rsync"					\
            "$path/tmp-eglibc/deploy/ipk" "$dest/packages"
}

do_oe_copy_licenses()
{
        local path="$1"
        local binaries="tmp-eglibc/deploy/images"

        pushd "$path"

        # Copy list of packages and licences for each image
        local licences="$OUTPUT_DIR/$NAME/raw/licences"

        rm -rf "$licences"
        mkdir -p "$OUTPUT_DIR/$NAME/raw/licences"

        for i in "$binaries"/*-image-licences.csv ; do
            local target="$(basename "$i" |
                          sed 's/[^-]*-\(.*-\)image-\(licences.csv\)$/\1\2/')"
            cp "$i" "$licences/$target"
        done

        # Verify that dom0 licences were copied
        [ -e "$licences/dom0-licences.csv" ]

        popd
}

do_oe_merge_src_info()
{
        local path="$1"

        if [ "$SOURCE" -eq 0 ]
        then
                echo "Skipping 'sourceinfo' step: '-S' option was not specified"
                return
        fi

        mkdir -p "$OUTPUT_DIR/$NAME/raw"

        "${CMD_DIR}/merge_src_info.py" \
            "$path/oe/tmp-eglibc/deploy/src-info" \
            "$OUTPUT_DIR/$NAME/raw/source-info.json"
}

do_sync_cache()
{
    set +o pipefail
    mkdir -p "$OE_BUILD_CACHE"
    if [ $VERBOSE -eq 1 ]
    then
	OPTS="-ltvzr --progress"
    else
	OPTS="-ltzr"
    fi
    [ "x$SYNC_CACHE_OE" != "x" ] && \
        rsync $OPTS -u --exclude ".*" "$SYNC_CACHE_OE/downloads" "$OE_BUILD_CACHE"

    # Get the last version of each package
    # FIXME: We explicitely exclude obselete folders from the list, as they still exist $SYNC_CACHE_OE
#    OIFS=$IFS
#    IFS=$'\n'
#    for i in `find $SYNC_CACHE_OE/oe-archive/$ORIGIN_BRANCH -name Packages | grep -v xenclient-iovm | grep -v xenclient-vpnvm`; do
#        folder=`dirname $i | sed "s|^$SYNC_CACHE_OE/oe-archive/||"`
#        grep "^Filename: " $i | sed "s|^Filename: |$folder/|"
#    done | rsync -ltvvzru --no-whole-file --files-from=- "$SYNC_CACHE_OE/oe-archive/" "$OE_BUILD_CACHE/oe-archive"
#    IFS=$OIFS
    set -o pipefail
}

do_sync_cache_back()
{
    set +o pipefail
    if [ "x$SYNC_CACHE_OE" != "x" ]; then
        rsync -ltzru --exclude "*[Oo]pen[Xx][Tt]*" "$OE_BUILD_CACHE/downloads" "$SYNC_CACHE_OE"
#        sudo rsync -ltzru --no-whole-file --ignore-existing "$OE_BUILD_CACHE/oe-archive" "$SYNC_CACHE_OE"
#
#        # Rsync the previously evicted package list files
#        for i in `find $OE_BUILD_CACHE/oe-archive -name "Packages*"`; do
#            echo $i | sed "s|^$OE_BUILD_CACHE/oe-archive/||"
#        done | sudo rsync -ltvvzru --no-whole-file --files-from=- "$OE_BUILD_CACHE/oe-archive/" "$SYNC_CACHE_OE/oe-archive"
    fi
    set -o pipefail
}

do_cleanup()
{
        set +o pipefail
        local path="$1"
        local ramdisk="$path/oe"

        # Kill old process that could use this directory
        lsof | grep "$(pwd)/$path/" | awk '{print $2}' | while read pid; do
                [ "$$" != "$pid" ] && kill -9 "$pid" || true
        done

        local type="`df -T "$ramdisk" | tail -n1 | awk '{print $2}'`"
        local dev="`df -T "$ramdisk" | tail -n1 | awk '{print $1}'`"
        if [ "$type" == "tmpfs" ]; then
                sudo umount "$ramdisk"
        elif [ "$dev" == "/dev/ram0" ]; then
                sudo umount "$ramdisk"
        fi
        sudo rm -rf "$ramdisk"
        mkdir -p "$ramdisk"
        sudo rm -rf "$path"
        set -o pipefail
}

list_manifest_suffixes()
{
        (
                cd "$CMD_DIR"
                find . -maxdepth 1 -name "manifest-*" | sort | \
                    sed 's/^\.\/manifest//'
        )
}

repository_add()
{
        local repository="$1"
        local shortname="$2"
        local format="$3"
        local required="$4"
        local filename="$5"
        local unpackdir="$6"

        (
                cd "$repository"
                local filesize=$( du -b $filename | awk '{print $1}' )
                local sha256sum=$( sha256sum $filename | awk '{print $1}' )

                echo "$shortname" "$filesize" "$sha256sum" "$format" \
                     "$required" "$filename" "$unpackdir" | tee -a XC-PACKAGES
        )
}

# fills repository$1 according to manifest$1
generic_do_repository()
{
        local suffix="$1"
        local info="$2"

        local repository="$OUTPUT_DIR/$NAME/repository$suffix/packages.main"

        mkdir -p "$repository"
        echo -n > "$repository/XC-PACKAGES"

        # Format of the manifest file is
        # name format optional/required source_filename dest_path
        while read l
        do
                local name=`echo "$l" | awk '{print $1}'`
                local format=`echo "$l" | awk '{print $2}'`
                local opt_req=`echo "$l" | awk '{print $3}'`
                local src=`echo "$l" | awk '{print $4}'`
                local dest=`echo "$l" | awk '{print $5}'`

                if [ ! -e "$OUTPUT_DIR/$NAME/raw/$src" ] ; then
                    if [ "$opt_req" = "required" ] ; then
                        echo "Error: Required file $src is missing"
                        exit 1
                    fi

                    echo "Optional file $src is missing: skipping"
                    break
                fi

                cp "$OUTPUT_DIR/$NAME/raw/$src" "$repository/$src"

                repository_add "$repository" "$name" "$format" "$opt_req" \
                               "$src" "$dest"
        done < "$CMD_DIR/manifest$suffix"

        PACKAGES_SHA256SUM=$(sha256sum "$repository/XC-PACKAGES" |
                             awk '{print $1}')

set +o pipefail #fragile part

        # Pad XC-REPOSITORY to 1 MB with blank lines. If this is changed, the
        # repository-signing process will also need to change.
        {
            cat <<EOF
xc:main
pack:Base Pack
product:XenClient
build:${ID}
version:${VERSION}
release:${RELEASE}
upgrade-from:${UPGRADEABLE_RELEASES}
packages:${PACKAGES_SHA256SUM}
EOF
            yes ""
        } | head -c 1048576 > "$repository/XC-REPOSITORY"

set -o pipefail #end of fragile part

        "${CMD_DIR}/sign_repo.sh" \
            "$(resolve_path "$TOPDIR" "$REPO_DEV_SIGNING_CERT")" \
            "$(resolve_path "$TOPDIR" "$REPO_DEV_SIGNING_KEY")" \
            "$repository"

        echo "repository$suffix: repository$suffix" >> "$info"
}

# fills each repository<suffix> according to manifest<suffix>
do_repositories()
{
        (
                local info_dir="$OUTPUT_DIR/$NAME/raw/info"
                local info="$info_dir/repository"

                mkdir -p "$info_dir"
                rm -f "$info"

                for suffix in "" `list_manifest_suffixes` ; do
                    echo "Repository$suffix:"

                    generic_do_repository "$suffix" "$info"
                done

                echo ""
        )
}

# Resolve $2 as an absolute path, or a path relative to $1
resolve_path()
{
    case "$2" in
        /*) echo "$2" ;;
        *)  echo "$1/$2" ;;
    esac
}

get_file_from_tar_or_cpio()
{
        local tarball="$1"
        local file="$2"

        if [ -f "$1.tar.bz2" ]; then
            tar -xOf "$1.tar.bz2" "./$file"
        elif [ -f "$1.cpio.gz" ]; then
            zcat "$1.cpio.gz" | cpio -i --to-stdout "$file"
        elif [ -f "$1.cpio.bz2" ]; then
            bzcat "$1.cpio.bz2" | cpio -i --to-stdout "$file"
        else
            false
        fi
}

generic_do_update()
{
        local suffix="$1"
        local info="$2"

        local update_name="update/update$suffix.tar"

        echo "update$suffix:"
        mkdir -p "$OUTPUT_DIR/$NAME/update"
        tar -C "$OUTPUT_DIR/$NAME/repository$suffix" \
            -cf "$OUTPUT_DIR/$NAME/$update_name" packages.main

        echo "ota-update$suffix: $update_name" >> "$info"
}

do_updates()
{
        local info_dir="$OUTPUT_DIR/$NAME/raw/info"
        local info="$info_dir/update"

        mkdir -p "$info_dir"
        rm -f "$info"

        for suffix in "" `list_manifest_suffixes`; do
                generic_do_update "$suffix" "$info"
        done
}

ACM_LIST="ivb_snb.acm gm45.acm duali.acm quadi.acm q35.acm q45q43.acm xeon56.acm xeone7.acm hsw.acm"

extract_acms()
{
        local tarball="$1"
        local src="$2"
        local dst="$3"

	for ACM in $ACM_LIST; do
                echo "    - extract $ACM"
                if [ -f "$src/$ACM" ]; then
                        cp "$src/$ACM" "$dst/$ACM"
                else
                        get_file_from_tar_or_cpio "$tarball" "boot/$ACM" > "$dst/$ACM"
                fi
        done
}

generic_do_netboot()
{
        local suffix="$1"
        local info="$2"

        local path="$OUTPUT_DIR/$NAME/raw/installer"
        local netboot="$OUTPUT_DIR/$NAME/netboot$suffix"
        local tarball="$path/rootfs.i686"

        echo "netboot$suffix:"

        rm -rf "$netboot"
        mkdir -p "$netboot"
        cp "$path/netboot/"* "$netboot"

        echo "  - extract xen.gz"
        if [ -f "$path/xen.gz" ]; then
                cp "$path/xen.gz" "$netboot/xen.gz"
        else
                get_file_from_tar_or_cpio "$tarball" "boot/xen-3.4.1-xc.gz" > "$netboot/xen.gz"
        fi
        echo "  - extract vmlinuz"
        if [ -f "$path/vmlinuz" ]; then
                cp "$path/vmlinuz" "$netboot/vmlinuz"
        else
                get_file_from_tar_or_cpio "$tarball" "boot/vmlinuz" > "$netboot/vmlinuz"
        fi
        echo "  - extract tboot.gz"
        if [ -f "$path/tboot.gz" ]; then
                cp "$path/tboot.gz" "$netboot/tboot.gz"
        else
                get_file_from_tar_or_cpio "$tarball" "boot/tboot.gz" > "$netboot/tboot.gz"
        fi
        echo "  - extract ACMs"
        extract_acms "$tarball" "$path" "$netboot"
        echo "  - copy rootfs"
        cp "$path/rootfs.i686.cpio.gz" "$netboot/rootfs.gz"

        echo "  - Create a tarball with netboot file"
        tar cf "$netboot/netboot.tar" -C "$netboot" .
        gzip -9 "$netboot/netboot.tar"

        echo "netboot$suffix: netboot$suffix" >> "$info"

        echo ""
}

do_netboots()
{
        local info_dir="$OUTPUT_DIR/$NAME/raw/info"
        local info="$info_dir/netboot"

        mkdir -p "$info_dir"
        rm -f "$info"

        for suffix in "" `list_manifest_suffixes` ; do
                generic_do_netboot "$suffix" "$info"
        done
}

generic_do_installer_iso()
{
        local suffix="$1"
        local info="$2"

        local path="$OUTPUT_DIR/$NAME/raw"
        local repository="$OUTPUT_DIR/$NAME/repository$suffix"
        local iso="$OUTPUT_DIR/$NAME/iso"
        local iso_path="$iso/installer$suffix"
        local tarball="$path/installer/rootfs.i686"
        local OPENXT_VERSION="$VERSION"
        local OPENXT_BUILD_ID="$ID"
        local OPENXT_ISO_LABEL="OpenXT-${VERSION}"
        echo "installer$suffix iso:"
        rm -rf "$iso_path" "$iso_path.iso"
        mkdir -p "$iso_path/isolinux"

        cp "$path/installer/iso/"* "$iso_path/isolinux"
        sed -i'' -re "s|[$]OPENXT_VERSION|$OPENXT_VERSION|g" "$iso_path/isolinux/bootmsg.txt"
        sed -i'' -re "s|[$]OPENXT_BUILD_ID|$OPENXT_BUILD_ID|g" "$iso_path/isolinux/bootmsg.txt"

        echo "  - extract xen.gz"
        if [ -f "$path/installer/xen.gz" ]; then
                cp "$path/installer/xen.gz" "$iso_path/isolinux/xen.gz"
        else
                get_file_from_tar_or_cpio "$tarball" "boot/xen-3.4.1-xc.gz" > "$iso_path/isolinux/xen.gz"
        fi
        echo "  - extract vmlinuz"
        if [ -f "$path/installer/vmlinuz" ]; then
                cp "$path/installer/vmlinuz" "$iso_path/isolinux/vmlinuz"
        else
                get_file_from_tar_or_cpio "$tarball" "boot/vmlinuz" > "$iso_path/isolinux/vmlinuz"
        fi
        echo "  - extract tboot.gz"
        if [ -f "$path/installer/tboot.gz" ]; then
                cp "$path/installer/tboot.gz" "$iso_path/isolinux/tboot.gz"
        else
                get_file_from_tar_or_cpio "$tarball" "boot/tboot.gz" > "$iso_path/isolinux/tboot.gz"
        fi
        echo "  - extract ACMs"
        extract_acms "$tarball" "$path/installer/" "$iso_path/isolinux"
        echo "  - copy rootfs"
        cp "$path/installer/rootfs.i686.cpio.gz" "$iso_path/isolinux/rootfs.gz"

        cp -r "$repository/"* "$iso_path"

        echo "  - create iso"
        "${CMD_DIR}/do_installer_iso.sh" "$iso_path" "$iso_path.iso" "$OPENXT_ISO_LABEL"

        rm -rf "$iso_path"

        echo "installer$suffix: iso/installer$suffix.iso" >> "$info"

        echo ""
}

do_installer_isos()
{
        local info_dir="$OUTPUT_DIR/$NAME/raw/info"
        local info="$info_dir/installer"

        mkdir -p "$info_dir"
        rm -f "$info"

        for suffix in "" `list_manifest_suffixes` ; do
                generic_do_installer_iso "$suffix" "$info"
        done
}


do_sdk()
{
        local path=`pwd`
        local workdir="${path}/sdk-tmp/"

	local xct="$OUTPUT_DIR/$NAME/raw"

	echo "Create sdk"
	rm -rf ${workdir}
	mkdir -p ${workdir}/openxt-sdk/

	echo "Clone xenclient/sdk.git"
	git_clone "${workdir}/openxt-sdk" "$OPENXT_GIT_PROTOCOL://$OPENXT_GIT_MIRROR/sdk.git" "$BRANCH" "$ALLOW_SWITCH_BRANCH_FAIL"

	echo "Get the windows stuff"
	if [ -e  "$xct/sdk.zip" ];
	then
 	   ( cd "${workdir}/openxt-sdk/Guest_VM/MS_Windows/" ; unzip "$xct/sdk.zip" )
	fi
	
	echo "Create archives"
	pushd ${workdir}
	rm -rf ${workdir}/openxt-sdk/.git
	rm -rf ${workdir}/openxt-sdk/.gitignore
	echo "$NAME" > openxt-sdk/ver
	date >> openxt-sdk/ver

	tar -czvf openxt-sdk.tar.gz openxt-sdk/
	popd
	
	echo "Copy sdk to output dir ${OUTPUT_DIR}/${NAME}/sdk/"
	mkdir -p ${OUTPUT_DIR}/${NAME}/sdk/
	cp -v ${workdir}/openxt-sdk.tar.gz ${OUTPUT_DIR}/${NAME}/sdk/
}

do_source_info()
{
        if [ "$SOURCE" -eq 0 ]
        then
                echo "Not generating source info: '-S' option was not specified"
                return
        fi

        echo "source info:"
        echo "  - copy source info"

        cp "$OUTPUT_DIR/$NAME/raw/source-info.json" \
           "$OUTPUT_DIR/$NAME/source-info.json"

        echo
}

do_licences()
{
        local licences="$OUTPUT_DIR/$NAME/raw/licences"
        local out="$OUTPUT_DIR/$NAME/licences"

        [ ! -d "$licences" ] && return

        echo "licences:"
        echo "  - copy package licence lists"

        rm -rf "$out"
        mkdir -p "$out"
        cp "$licences"/* "$out"

        echo
}

check_iso_size()
{
        local dir="$1"
        local max_sectors=333000
        local sectors=$(genisoimage -print-size -r -J -f -quiet "$dir")

        [ $sectors -le $max_sectors ]
}

copy_source_dirs()
{
        local iso="$1"
        shift

        local n=1

        while [ "$#" -ne 0 ]
        do
                local iso_dir="$iso/source-$n"

                if [ ! -d "$iso_dir" ]
                then
                        mkdir "$iso_dir"
                        local first=1
                fi

                cp -rl "$1" "$iso_dir"

                if check_iso_size "$iso_dir"
                then
                        shift
                else
                        if [ "$first" ]
                        then
                                echo "Error: source directory '$(pwd)/$1' is too large"
                                exit 1
                        fi

                        rm -rf "$iso_dir/$1"
                        n=$[$n + 1]
                fi

                first=
        done

        echo $n
}

generate_source_iso()
{
        local iso="$1"
        local num_isos="$2"
        local info="$3"

        echo -n "sources: " > "$info"

        local n
        for n in $(seq -s" " 1 $num_isos)
        do
                if [ $num_isos -gt 1 ]
                then
                        local iso_name="source-$n-of-$num_isos.iso"
                else
                        local iso_name="source.iso"
                fi

                genisoimage -o "$iso/$iso_name" -r -J -f -quiet "$iso/source-$n"
                rm -rf "$iso/source-$n"

                echo -n "iso/$iso_name " >> "$info"
        done

        echo >> "$info"
}

do_source_iso()
{
        local path="$OUTPUT_DIR/$NAME/raw"
        local iso="$OUTPUT_DIR/$NAME/iso"
        local info_dir="$OUTPUT_DIR/$NAME/raw/info"
        local info="$info_dir/source"

        if [ "$SOURCE" -eq 0 ]
        then
                echo "Not generating source iso: '-S' option was not specified"
                return
        fi

        mkdir -p "$info_dir"
        rm -f "$info"

        pushd "$path/source" > /dev/null

        echo "source iso:"
        rm -rf "$iso/source-"* "$iso/source.iso"
        mkdir -p "$iso"

        echo "  - copy sources"
        num_isos=$(copy_source_dirs "$iso" *)
        
        echo "  - create iso"
        generate_source_iso "$iso" "$num_isos" "$info"

        popd > /dev/null
        echo
}

do_useexisting_xctools()
{
       local path="$1"

       mkdir -p "$path"
       pushd "$path"

       local xct="$OUTPUT_DIR/$NAME/raw"
       mkdir -p "$xct"
      
       echo "Copy windows zip files from $XC_TOOLS_OBJECTS_ORIGIN"
       rsync -v "$XC_TOOLS_OBJECTS_ORIGIN/*.zip" "$xct"
       popd
}

do_debian_xctools()
{
    local path="$1"
    local debdir="$2"

    mkdir -p ${debdir}

    echo $path
    echo $debdir

    # some day somebody will refactor this... or maybe not.
    export BUILD_SCRIPTS OPENXT_GIT_MIRROR BRANCH ALLOW_SWITCH_BRANCH_FAIL VERBOSE XENCLIENT_TOOLS XEN_VERSION_BRANCH OPENXT_GIT_PROTOCOL
    export XEN_VERSION XEN_SRC_URI

    # add linux xctools artifacts
    for n in pkg-xctools pkg-xcswitcher; do
        ${BUILD_SCRIPTS}/$n/build ${path}
        ${BUILD_SCRIPTS}/$n/install ${debdir}
    done
}

xctools_iso_from_zip()
{
    local path="$1"
#    local pkgdir="$OE_BUILD_CACHE/oe-archive/$ORIGIN_BRANCH/all"
#    local linuxtools_ipk=$pkgdir/`grep "^Filename: xenclient-linuxtools_" $pkgdir/Packages | head -n1 | sed 's/^Filename: //'`
    local raw="$OUTPUT_DIR/$NAME/raw"
    local label="OpenXT-tools"
    local isodir="xc-tools-tmp/linux"

#    echo "Linuxtools IPK is $linuxtools_ipk"
    rm -rf xc-tools-tmp
    mkdir -p xc-tools-tmp
    if [ -e ${raw}/xctools-iso.zip ]; then
     unzip "${raw}/xctools-iso.zip" -d xc-tools-tmp
    elif [ -e ${raw}/xc-tools.zip ]; then
      unzip "${raw}/xc-tools.zip" -d xc-tools-tmp
    else
      die "zip file with windows tools was not found"
    fi

    do_debian_xctools ${path} ${isodir}

    # create the ISO
    genisoimage -R -J -joliet-long -input-charset utf8 -o "${raw}/xc-tools.iso" -V "$label" xc-tools-tmp

    rm -rf xc-tools-tmp
}

do_xctools_debian_repo()
{
    local path=`cd "$1"; pwd`
    local dest_dir="${path}/oe/tmp-eglibc/deb-xctools-image/"
    local d_output_dir="${OUTPUT_DIR}/${NAME}/xctools-debian-repo/debian"

    echo "Building Debian Service VM tools"
    do_oe "${path}" "xenclient-nilfvm" "linux-xenclient-nilfvm" 1
    do_oe "${path}" "xenclient-nilfvm" "deb-servicevm-tools" 1

    echo "Building XC Tools Debian/Ubuntu repository"
    do_oe "${path}" "xenclient-dom0" "deb-xctools-image" 1

    [[ -d "${dest_dir}/debian" ]] || die "do_xctools_debian_repo: debian repository does not exist"
    mkdir -p "${d_output_dir}"
    rsync -a --delete "${dest_dir}/debian/" "${d_output_dir}"
    ( cd "${OUTPUT_DIR}/${NAME}/xctools-debian-repo/" && tar czpf xctools-debian-repo.tar.gz * )
}

do_xctools_debian_repo_copy()
{
    rsync -ltzr --chmod=Fgo+r,Dgo+rx "$OUTPUT_DIR/$NAME" "$BUILD_RSYNC_DESTINATION/$ORIGIN_BRANCH"
}

do_xctools_win()
{
    local path="$1"
    local uid="$NAME"

    if [ -z "${WIN_BUILD_OUTPUT}" ] ; then
        echo "Error: WIN_BUILD_OUTPUT must be set in .config or passed in via" \
             "the -w option." >&2
        false
    fi

    mkdir -p "$path"
    pushd "$path"
    
            rm -rf "xc-tools.iso"
 	    rsync -r -v --progress "${WIN_BUILD_OUTPUT}/" ./

            local xct="$OUTPUT_DIR/$NAME/raw"
            mkdir -p "$xct"

            cp "xctools-iso.zip" "$xct" || exit 5
	    cp "sdk.zip" "$xct" || exit 4
            [ -f "win-tools.zip" ] && cp "win-tools.zip" "$xct"
            [ -f "xc-windows.zip" ] && cp "xc-windows.zip" "$xct"
            [ -f "oz-bits.zip" ] && cp "oz-bits.zip" "$xct"

        popd
}

do_xctools_linux() {
    local path="$1"

    pushd "$path"
    # build the linuxtools pkg, make iso with it
    if [ $ORIGIN_BRANCH != "tracy" ]; then
        xctools_iso_from_zip "./.."
    fi
    popd
}

do_xctools() {

        if [ ! "${XC_TOOLS_OBJECTS_ORIGIN}" ] ;
        then
                do_xctools_win "$1"
        else
               do_useexisting_xctools "$1"
        fi
       do_xctools_linux "$1"
}

do_syncui()
{
    local name="sync-wui-${RELEASE}.tar.gz"
    local file="$OUTPUT_DIR/$NAME/raw/$name"
    local out="$OUTPUT_DIR/$NAME/sync"

    echo "syncui:"
    echo "  - copy $name"

    mkdir -p "$out"
    cp "$file" "$out"

    echo
}

do_info()
{
    local out="$OUTPUT_DIR/$NAME"

    echo "info:"
    echo "  - generate info"

    sort "$out/raw/info/"* > "$out/info"
}

do_ship()
{
        do_repositories
        do_updates
        do_netboots
        do_installer_isos
        do_source_iso
        do_source_info
        do_licences
        do_syncui
        do_info
}

do_copy()
{
        echo "Copy output:"
        echo "   - $BUILD_RSYNC_DESTINATION/$ORIGIN_BRANCH/$NAME"

        rsync -ltzr --chmod=Fgo+r,Dgo+rx "$OUTPUT_DIR/$NAME" "$BUILD_RSYNC_DESTINATION/$ORIGIN_BRANCH"
}

do_bg()
{
        log="$CMD_DIR/$1.log"

        echo "Start task $1 (log=$log)"
        $* > "$log" 2>&1 &
}

get_version()
{
        . ${CMD_DIR}/version

        if [ "$ID" ] ; then
                # Build number is a 16-bit unsigned integer in Windows
                XC_TOOLS_BUILD=$((${ID} % 65536))
        else
                XC_TOOLS_BUILD=0
        fi

        XENCLIENT_TOOLS="$XC_TOOLS_MAJOR.$XC_TOOLS_MINOR.$XC_TOOLS_MICRO.$XC_TOOLS_BUILD"
}

do_rmoutput()
{
    sudo rm -rf "$OUTPUT_DIR/$NAME"
}

do_build()
{
        local path="build"

        get_version

        if [ "x$ARGNAME" != "x" ]; then
            NAME="$ARGNAME"
        else
            NAME="$NAME_SITE-$BUILD_TYPE-$ID-$BRANCH"
        fi

        mkdir -p "$CACHE_DIR"
        export CCACHE_DIR_TARGET="$CACHE_DIR"
        mkdir -p "$OUTPUT_DIR/$NAME/raw"

        OLDIFS="$IFS"
        IFS="," ; export IFS
	# work out number of steps
	# a patch for a shorter way to do this welcome :)
	NSTEPS=0
	for i in $STEPS
	do
	    NSTEPS=`expr $NSTEPS + 1`	    
	done

	# run each step
	STEPNUM=1
        for i in $STEPS
        do
	        echo "STARTING STEP $i (step $STEPNUM of $NSTEPS), started at" `date -u +'%H:%M:%S UTC'`
                IFS="$OLDIFS" ; export IFS

                name="`echo "$i" | cut -d" " -f1`"
                bg=""
                [ "`expr "$i" : ".* &"`" != "0" ] && bg="do_bg"
                case "$i" in
                        sync_cache_back*)
                                do_sync_cache_back ;;
                        sync_cache*)
                                do_sync_cache ;;
                        setupoe*)
			        # NOTE: the ramdisk is off by default so normally
			        # create_ramdisk is a no-op
                                create_ramdisk "$path/oe" "$RAMDISK" && \
                                do_oe_setup "$path" "$BRANCH"
                                ;;
                        extra_pkgs*)
                                do_oe_extra_pkgs "$path" ;; 
                        dom0)
                                $bg do_oe_dom0 "$path" ;;
                        dom0cp)
                                do_oe_dom0_copy "$path" ;;
                        sysroot)
                                $bg do_oe_sysroot "$path" ;;
                        sysrootcp)
                                do_oe_sysroot_copy "$path" ;;
                        initramfs*)
                                $bg do_oe "$path" "xenclient-dom0" "xenclient-initramfs-image" ;;
                        stubinitramfs)
                                $bg do_oe "$path" "xenclient-stubdomain" "xenclient-stubdomain-initramfs-image" ;;
                        installer)
                                $bg do_oe_installer "$path" ;;
                        installercp)
                                do_oe_installer_copy "$path" ;;
                        installer2)
                                $bg do_oe_installer_part2 "$path" ;;
                        installer2cp)
                                do_oe_installer_part2_copy "$path" ;;
                        license*)
                                $bg do_oe_copy_licenses "$path" ;;
                        sourceinfo*)
                                $bg do_oe_merge_src_info "$path" ;;
                        uivm)
                                $bg do_oe_uivm "$path" ;;
                        ndvm)
                                $bg do_oe_ndvm "$path" ;;
                        nilfvm)
                                $bg do_oe_nilfvm "$path" ;;
                        vpnvm)
                                # for retro-compatibility
                                $bg do_oe_nilfvm "$path" ;;
                        syncvm)
                                $bg do_oe_syncvm "$path" ;;
                        syncui)
                                $bg do_oe_syncui "$path" ;;
                        uivmcp)
                                do_oe_uivm_copy "$path" ;;
                        ndvmcp)
                                do_oe_ndvm_copy "$path" ;;
                        vpnvmcp)
                                do_oe_vpnvm_copy "$path" ;;
                        syncvmcp)
                                do_oe_syncvm_copy "$path" ;;
                        syncuicp)
                                do_oe_syncui_copy "$path" ;;
                        xctools*)
                                $bg do_xctools "$path/xctools" ;;
                        debian)
                                $bg do_debian_xctools "." "xc-tools-tmp/linux" ;;
                        oldxctools*)
                                $bg do_useexisting_xctools "$path/xctools" ;;
                        debian_repo_xctools)
                                do_xctools_debian_repo "$path" ;;
                        debian_repo_xctools_copy)
                                do_xctools_debian_repo_copy "$path" ;;
                        ship*)
                                do_ship ;;
                        source)
                                do_oe_source "$path" ;;
                        sourcecp)
                                do_oe_source_copy "$path" ;;
                        copy*)
                                do_copy ;;
                        packages_tree*)
                                do_oe_packages_tree "$path" ;;
                        sim*)
                                $bg do_sim "$path/xc-sim" ;;
                        cleanup*)
                                do_cleanup "$path" ;;
		        sdk)
			        do_sdk ;;
                        rmoutput*)
                                do_rmoutput ;;
                        wait*)
                                arg="`echo "$i" | cut -d" " -f2`"
                                eval pid='$'"${arg}_pid"
                                echo "Wait for task $arg (pid=$pid)"
                                wait "$pid" ||  \
                                ( echo "Task $arg failed" ; \
                                tail "$CMD_DIR/$arg.log" && exit "$?" )
                                ;;
		        *)
			        echo "ERROR: unknown step $i"
				exit 1
                esac
                pid="$!"
                eval "${name}_pid=$pid"
		STEPNUM=`expr $STEPNUM + 1`
        done
}


usage()
{
        echo "$CMD: [-b branch (default: master)] [-i id] [-s steps] [-e ] [-N name] [-d rsync_destination] [-S]"
}

sanitize_build_id() {
        echo "$1" | grep -q '^[0-9]\+$'
}

if [ "x$CONFIG" != "x" ] ; then
        . "$CONFIG"
else
        if [ ! -f ".config" ] ; then
                echo ".config file is missing"
                exit 1
        fi
        . .config
fi

RAMDISK=0
ORIGIN_BRANCH="$BRANCH"
BUILD_SCRIPTS="`pwd`/`dirname $0`"

while [ "$#" -ne 0 ]; do
        case "$1" in
                -b) ORIGIN_BRANCH="$2" ; BRANCH="$2" ; shift 2 ;;
                -i) ID="$2"; sanitize_build_id "$ID" || die "Invalid build id: '$ID'"; shift 2 ;;
                -s) STEPS="$2"; shift 2;;
                -e) ENV=1; shift 1;;
                -v) VERBOSE=1; shift 1;;
                -m) RAMDISK=1; shift ;;
                -M) RAMDISK=2; shift ;;
                -N) ARGNAME="$2"; shift 2;;
                -S) SOURCE=1; shift ;;
	        -d) BUILD_RSYNC_DESTINATION="$2"; shift 2;; 
	        -w) WIN_BUILD_OUTPUT="$2"; shift 2;; 
                --) shift ; break ;;
                *) usage ; exit 1;;
        esac
done

[ "x$DEBUG" != "x" ] && env >&2 && set -x

do_build
