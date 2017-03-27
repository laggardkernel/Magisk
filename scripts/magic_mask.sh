#!/system/bin/sh

LOGFILE=/cache/magisk.log
DISABLEFILE=/cache/.disable_magisk
UNINSTALLER=/cache/magisk_uninstaller.sh
IMG=/data/magisk.img
WHITELIST="/system/bin"

MOUNTPOINT=/magisk

COREDIR=$MOUNTPOINT/.core

TMPDIR=/dev/magisk
DUMMDIR=$TMPDIR/dummy
MIRRDIR=$TMPDIR/mirror
MOUNTINFO=$TMPDIR/mnt

# Use the included busybox for maximum compatibility and reliable results
# e.g. we rely on the option "-c" for cp (reserve contexts), and -exec for find
TOOLPATH=/dev/busybox
# BINPATH=/data/magisk
DATABIN=/data/magisk
MAGISKBIN=$COREDIR/bin
OLDPATH=$PATH
export PATH=$TOOLPATH:$OLDPATH

APPDIR=/data/data/com.topjohnwu.magisk/files

# Default permissions
umask 022

log_print() {
  echo "$1"
  echo "$1" >> $LOGFILE
  log -p i -t Magisk "$1"
}

mktouch() {
  mkdir -p "${1%/*}" 2>/dev/null
  if [ -z "$2" ]; then
    touch "$1" 2>/dev/null
  else
    echo "$2" > "$1" 2>/dev/null
  fi
}

in_list() {
  for i in $2; do
    [ "$1" = "$i" ] && return 0
  done
  return 1
}

unblock() {
  touch /dev/.magisk.unblock
  chcon u:object_r:device:s0 /dev/.magisk.unblock
  exit
}

bind_mount() {
  if [ -e "$1" -a -e "$2" ]; then
    mount -o bind "$1" "$2"
    if [ "$?" -eq "0" ]; then
      log_print "Mount: $1"
    else
      log_print "Mount Fail: $1 -> $2"
    fi
  fi
}

loopsetup() {
  LOOPDEVICE=
  for DEV in $(ls /dev/block/loop*); do
    if [ `losetup $DEV $1 >/dev/null 2>&1; echo $?` -eq 0 ]; then
      LOOPDEVICE=$DEV
      break
    fi
  done
}

image_size_check() {
  e2fsck -yf $1
  curBlocks=`e2fsck -n $1 2>/dev/null | grep $1 | cut -d, -f3 | cut -d\  -f2`; 
  curUsedM=`echo "$curBlocks" | cut -d/ -f1`
  curSizeM=`echo "$curBlocks" | cut -d/ -f1`
  curFreeM=$(((curSizeM - curUsedM) * 4 / 1024))
  curUsedM=$((curUsedM * 4 / 1024 + 1))
  curSizeM=$((curSizeM * 4 / 1024))
}

run_scripts() {
  BASE=$MOUNTPOINT
  for MOD in $BASE/* ; do
    if [ ! -f "$MOD/disable" ]; then
      if [ -f "$MOD/$1.sh" ]; then
        chmod 755 "$MOD/$1.sh"
        chcon "u:object_r:system_file:s0" "$MOD/$1.sh"
        log_print "$1: $MOD/$1.sh"
        sh "$MOD/$1.sh"
      fi
    fi
  done
  for SCRIPT in $COREDIR/${1}.d/* ; do
    if [ -f "$SCRIPT" ]; then
      chmod 755 "$SCRIPT"
      chcon "u:object_r:system_file:s0" "$SCRIPT"
      log_print "${1}.d: $SCRIPT"
      sh "$SCRIPT"
    fi
  done
}

travel() {
  # LINK=false
  # in_list "/$1" "$WHITELIST" && LINK=true
  
  cd "$TRAVEL_ROOT/$1"
  if [ -f ".replace" ]; then
    log_print "Replace: /$1"
    rm -rf "$MOUNTINFO/$1"
    mktouch "$MOUNTINFO/$1" "$TRAVEL_ROOT"
  else
    for ITEM in * ; do
      # This means it's an empty folder (shouldn't happen, but better to be safe)
      [ "$ITEM" = "*" ] && return
      # Ignore /system/vendor since we will handle it differently
      # [ "$1" = "system" -a "$ITEM" = "vendor" ] && continue

      # Target not found or target/file is a symlink
      if [ ! -e "/$1/$ITEM" -o -L "/$1/$ITEM" -o -L "$ITEM" ]; then
        # New item found
        if [ "$1" = "system" ]; then
          # We cannot add new items to /system root, delete it
          # bind_mount is still used to get mirror system due to compatibility with MultiROM
          rm -rf "$ITEM"
        else
          # If we are in a higher level, delete the lower levels
          rm -rf "$MOUNTINFO/dummy/$1" 2>/dev/null
          # Mount the dummy parent
          log_print "Replace with dummy: /$1"
          mktouch "$MOUNTINFO/dummy/$1"

          if [ -L "$ITEM" ]; then
            # Copy symlinks
            log_print "Symlink: /$1/$ITEM"
            mkdir -p "$DUMMDIR/$1" 2>/dev/null
            cp -afc "$ITEM" "$DUMMDIR/$1/$ITEM"
          elif [ -d "$ITEM" ]; then
            # Create new dummy directory and mount it
            log_print "New directory: /$1/$ITEM"
            mkdir -p "$DUMMDIR/$1/$ITEM"
            mktouch "$MOUNTINFO/$1/$ITEM" "$TRAVEL_ROOT"
          else
            # Create new dummy file and mount it
            log_print "New file: /$1/$ITEM"
            mktouch "$DUMMDIR/$1/$ITEM"
            mktouch "$MOUNTINFO/$1/$ITEM" "$TRAVEL_ROOT"
          fi
        fi
      else
        if [ -d "$ITEM" ]; then
          # It's an directory, travel deeper
          (travel "$1/$ITEM")
        elif [ ! -L "$ITEM" ]; then
          # Mount this file
          log_print "Replace: /$1/$ITEM"
          mktouch "$MOUNTINFO/$1/$ITEM" "$TRAVEL_ROOT"
        fi
      fi
    done
  fi
}

clone_dummy() {
  LINK=false
  in_list "$1" "$WHITELIST" && LINK=true
  
  for ITEM in "$1/"* ; do
    if [ ! -e "$DUMMDIR$ITEM" ]; then
      if [ ! -d "$MOUNTINFO$ITEM" ]; then
        # Copy binary anyway in case of replacement
        if $LINK; then
          cp -afc "$ITEM" "$DUMMDIR$ITEM"
        elif [ -d "$ITEM" ]; then
          # Create dummy directory
          mkdir -p "$DUMMDIR$ITEM"
        elif [ -L "$ITEM" ]; then
          # Symlinks are small, copy them
          cp -afc "$ITEM" "$DUMMDIR$ITEM"
        else
          # Create dummy file
          mktouch "$DUMMDIR$ITEM"
        fi
        chcon -f "u:object_r:system_file:s0" "$DUMMDIR$ITEM"
      else
        # Need to clone a skeleton
        (clone_dummy "$ITEM")
      fi
    elif [ -d "$DUMMDIR$ITEM" ]; then
      # Need to clone a skeleton
      (clone_dummy "$ITEM")
    fi
  done
}

merge_image() {
  if [ -f $1 ]; then
    log_print "$1 found"
    if [ -f $IMG ]; then
      log_print "$IMG found, attempt to merge"

      # Handle large images
      image_size_check $1
      mergeUsedM=$curUsedM
      image_size_check $IMG
      if [ "$mergeUsedM" -gt "$curFreeM" ]; then
        NEWDATASIZE=$(((mergeUsedM + curUsedM) / 32 * 32 + 32))
        log_print "Expanding $IMG to ${NEWDATASIZE}M..."
        resize2fs $IMG ${NEWDATASIZE}M
      fi

      # Start merging
      mkdir /cache/data_img
      mkdir /cache/merge_img

      # setup loop devices
      loopsetup $IMG
      LOOPDATA=$LOOPDEVICE
      log_print "$LOOPDATA $IMG"

      loopsetup $1
      LOOPMERGE=$LOOPDEVICE
      log_print "$LOOPMERGE $1"

      if [ ! -z $LOOPDATA -a ! -z $LOOPMERGE ]; then
        # if loop devices have been setup, mount images
        OK=false
        mount -t ext4 -o rw,noatime $LOOPDATA /cache/data_img && \
        mount -t ext4 -o rw,noatime $LOOPMERGE /cache/merge_img && \
        OK=true

        if $OK; then
          # Merge (will reserve selinux contexts)
          cd /cache/merge_img
          for MOD in *; do
            if [ "$MOD" != "lost+found" ]; then
              log_print "Merging: $MOD"
              rm -rf /cache/data_img/$MOD
            fi
          done
          cp -afc . /cache/data_img
          log_print "Merge complete"
          cd /
        fi

        umount /cache/data_img
        umount /cache/merge_img
      fi

      losetup -d $LOOPDATA
      losetup -d $LOOPMERGE

      rmdir /cache/data_img
      rmdir /cache/merge_img
    else 
      log_print "Moving $1 to $IMG "
      mv $1 $IMG
    fi
    rm -f $1
  fi
}

case $1 in
  post-fs )
    mv $LOGFILE /cache/last_magisk.log
    touch $LOGFILE
    chmod 644 $LOGFILE

    # No more cache mods!
    # Only for multirom!

    log_print "** Magisk post-fs mode running..."

    # Cleanup previous version stuffs...
    rm -rf /cache/magisk /cache/magisk_merge /cache/magiskhide.log

    [ -f $DISABLEFILE -o -f $UNINSTALLER ] && unblock

    if [ -d "/cache/magisk_mount" ]; then
      log_print "* Mounting cache files"
      find /cache/magisk_mount -type f 2>/dev/null | while read ITEM ; do
        chmod 644 "$ITEM"
        chcon "u:object_r:system_file:s0" "$ITEM"
        TARGET="${ITEM#/cache/magisk_mount}"
        bind_mount "$ITEM" "$TARGET"
      done
    fi

    unblock
    ;;

  post-fs-data )
    if [ `mount | grep " /data " >/dev/null 2>&1; echo $?` -ne 0 ]; then
      # /data not mounted yet, we will be called again later
      unblock
    fi

    if [ `mount | grep " /data " | grep "tmpfs" >/dev/null 2>&1; echo $?` -eq 0 ]; then
      # /data not mounted yet, we will be called again later
      unblock
    fi

    # Don't run twice
    if [ "`getprop magisk.restart_pfsd`" != "1" ]; then

      log_print "** Magisk post-fs-data mode running..."

      # Cache support
      mv /cache/stock_boot* /data 2>/dev/null
      mv /cache/magisk.apk /data/magisk.apk 2>/dev/null
      mv /cache/custom_ramdisk_patch.sh /data/custom_ramdisk_patch.sh 2>/dev/null

      if [ -d /cache/data_bin ]; then
        rm -rf $DATABIN
        mv /cache/data_bin $DATABIN
      fi

      chmod -R 755 $DATABIN
      chown -R 0.0 $DATABIN

      # Live patch sepolicy
      # v9
      # $BINPATH/sepolicy-inject --live -s su
      # v11.1
      # $BINPATH/sepolicy-inject --live
      # v11.5/11.6
      # $BINPATH/magiskpolicy --live
      $DATABIN/magiskpolicy --live

      # Set up environment
      mkdir -p $TOOLPATH
      $DATABIN/busybox --install -s $TOOLPATH
      ln -sf $DATABIN/busybox $TOOLPATH/busybox
      # Prevent issues
      rm -f $TOOLPATH/su $TOOLPATH/sh $TOOLPATH/reboot
      chmod -R 755 $TOOLPATH
      chown -R 0.0 $TOOLPATH
      find $DATABIN $TOOLPATH -exec chcon -h u:object_r:system_file:s0 {} \;
      
      if [ -f $UNINSTALLER ]; then
        touch /dev/.magisk.unblock
        chcon u:object_r:device:s0 /dev/.magisk.unblock
        BOOTMODE=true sh $UNINSTALLER
        exit
      fi
      
      # Image merging
      chmod 644 $IMG /cache/magisk.img /data/magisk_merge.img 2>/dev/null
      merge_image /cache/magisk.img
      merge_image /data/magisk_merge.img
      
      # Mount magisk.img
      [ ! -d $MOUNTPOINT ] && mkdir -p $MOUNTPOINT
      if ! mount | grep $MOUNTPOINT; then
        loopsetup $IMG
        [ ! -z $LOOPDEVICE ] && mount -t ext4 -o rw,noatime $LOOPDEVICE $MOUNTPOINT
        if [ $? -ne 0 ]; then
          log_print "magisk.img mount failed, nothing to do :("
          unblock
        fi
      fi
      
      # Remove empty directories, legacy paths, symlinks, old temporary images
      find $MOUNTPOINT -type d -depth ! -path "*core*" -exec rmdir {} \; 2>/dev/null
      rm -rf $MOUNTPOINT/zzsupersu $MOUNTPOINT/phh $COREDIR/dummy $COREDIR/mirror \
             $COREDIR/busybox $COREDIR/su /data/magisk/*.img /data/busybox 2>/dev/null

      # Remove modules that are labeled to be removed
      for MOD in $MOUNTPOINT/* ; do
        rm -f $MOD/system/placeholder 2>/dev/null
        if [ -f $MOD/remove ]; then
          log_print "Remove module: $MOD"
          rm -rf $MOD
        fi
      done

      # Unmount, shrink, remount
      if umount $MOUNTPOINT; then
        losetup -d $LOOPDEVICE 2>/dev/null
        image_size_check $IMG
        NEWDATASIZE=$((curUsedM / 32 * 32 + 32))
        if [ "$curSizeM" -gt "$NEWDATASIZE" ]; then
          log_print "Shrinking $IMG to ${NEWDATASIZE}M..."
          resize2fs $IMG ${NEWDATASIZE}M
        fi
        loopsetup $IMG
        [ ! -z $LOOPDEVICE ] && mount -t ext4 -o rw,noatime $LOOPDEVICE $MOUNTPOINT
        if [ $? -ne 0 ]; then
          log_print "magisk.img mount failed, nothing to do :("
          unblock
        fi
      fi

      # v11.1 Start MagiskSU if no SuperSU
      # export PATH=$OLDPATH
      # [ ! -f /sbin/launch_daemonsu.sh ] && sh $COREDIR/su/magisksu.sh
      # export PATH=$TOOLPATH:$OLDPATH
      
      # Start MagiskSU
      log_print "* Linking binaries to /sbin"
      mount -o rw,remount rootfs /
      chmod 755 /sbin
      ln -sf $DATABIN/magiskpolicy /sbin/magiskpolicy
      ln -sf $DATABIN/magiskpolicy /sbin/sepolicy-inject
      ln -sf $MAGISKBIN/resetprop /sbin/resetprop
      if [ ! -f /sbin/launch_daemonsu.sh ]; then
        log_print "* Starting MagiskSU"
        export PATH=$OLDPATH
        ln -sf $MAGISKBIN/su /sbin/su
        ln -sf $DATABIN/magiskpolicy /sbin/supolicy
        /sbin/su --daemon
        export PATH=$TOOLPATH:$OLDPATH
      fi
      mount -o ro,remount rootfs /

      # Exit if disabled
      [ -f $DISABLEFILE ] && unblock
      
      # Multirom functions should go here, not available right now
      MULTIROM=false

      log_print "* Preparing modules"

      mkdir -p $DUMMDIR
      mkdir -p $MIRRDIR/system

      # Travel through all mods, all magic happens here
      for MOD in $MOUNTPOINT/* ; do
        if [ ! -f "$MOD/disable" ]; then
          # Travel through all mods
          if [ -f "$MOD/auto_mount" -a -d "$MOD/system" ]; then
            log_print "Analyzing module: $MOD"
            TRAVEL_ROOT=$MOD
            (travel system)
          fi
          # Read in defined system props
          if [ -f "$MOD/system.prop" ]; then
            log_print "* Reading props from $MOD/system.prop"
            $MAGISKBIN/resetprop --file "$MOD/system.prop"
          fi
        fi
      done

      # Proper permissions for generated items
      find $TMPDIR -exec chcon -h "u:object_r:system_file:s0" {} \;

      # linker(64), t*box required
      if [ -f "$MOUNTINFO/dummy/system/bin" ]; then
        cd /system/bin
        cp -afc linker* t*box $DUMMDIR/system/bin/
      fi

      # Some libraries are required
      LIBS="libc++.so libc.so libcutils.so libm.so libstdc++.so libcrypto.so liblog.so libpcre.so libselinux.so libpackagelistparser.so"
      if [ -f "$MOUNTINFO/dummy/system/lib" ]; then
        cd /system/lib
        cp -afc $LIBS $DUMMDIR/system/lib
        # Crash prevention!!
        # rm -f $COREDIR/magiskhide/enable 2>/dev/null
      fi
      if [ -f "$MOUNTINFO/dummy/system/lib64" ]; then
        cd /system/lib64
        cp -afc $LIBS $DUMMDIR/system/lib64
        # Crash prevention!!
        # rm -f $COREDIR/magiskhide/enable 2>/dev/null
      fi

      # vendor libraries are device dependent, had no choice but copy them all if needed....
      if [ -f "$MOUNTINFO/dummy/system/vendor" ]; then
        cp -afc /system/vendor/lib/. $DUMMDIR/system/vendor/lib
        [ -d "/system/vendor/lib64" ] && cp -afc /system/vendor/lib64/. $DUMMDIR/system/vendor/lib64
      fi
      if [ -f "$MOUNTINFO/dummy/system/vendor/lib" ]; then
        cp -afc /system/vendor/lib/. $DUMMDIR/system/vendor/lib
      fi
      if [ -f "$MOUNTINFO/dummy/system/vendor/lib64" ]; then
        cp -afc /system/vendor/lib64/. $DUMMDIR/system/vendor/lib64
      fi

      # Remove crap folder
      rm -rf $MOUNTPOINT/lost+found

      # Start doing tasks
      
      # Stage 1
      log_print "* Stage 1: Bind mount dummy skeletons"
      find $MOUNTINFO/dummy -type f 2>/dev/null | \
      while read ITEM ; do
        TARGET=${ITEM#$MOUNTINFO/dummy}
        ORIG="$DUMMDIR$TARGET"
        clone_dummy "$TARGET"
        bind_mount "$ORIG" "$TARGET"
      done
      
      # Check if the dummy /system/bin is empty, it shouldn't
      [ -e $DUMMDIR/system/bin -a ! -e $DUMMDIR/system/bin/sh ] && clone_dummy /system/bin

      # Stage 2
      log_print "* Stage 2: Bind mount module items"
      find $MOUNTINFO/system -type f 2>/dev/null | while read ITEM ; do
        TARGET=${ITEM#$MOUNTINFO}
        ORIG=`cat $ITEM`$TARGET
        bind_mount "$ORIG" "$TARGET"
        rm -f $DUMMDIR${TARGET%/*}/.dummy 2>/dev/null
      done

      # Stage 3, Run scripts
      log_print "* Stage 3: Execute scripts"
      run_scripts post-fs-data
      
      # Stage 4
      log_print "* Stage 4: Bind mount system mirror"
      bind_mount /system $MIRRDIR/system

      # Stage 5
      log_print "* Stage 5: Bind mount mirror items"
      # Find all empty directores and dummy files, they should be mounted by original files in /system
      TOOLPATH=/dev/busybox find $DUMMDIR -type d \
      -exec sh -c '[ -z "`ls -A $1`" ] && echo $1' -- {} \; \
      -o \( -type f -size 0 -print \) | \
      while read ITEM ; do
        ORIG=${ITEM/dummy/mirror}
        TARGET=${ITEM#$DUMMDIR}
        bind_mount "$ORIG" "$TARGET"
      done

      # Bind hosts for Adblock apps
      if [ -f "$COREDIR/hosts" ]; then
        log_print "* Enabling systemless hosts file support"
        bind_mount $COREDIR/hosts /system/etc/hosts
      fi

      if [ -f $DATABIN/magisk.apk ]; then
        if ! ls /data/app | grep com.topjohnwu.magisk; then
          mkdir /data/app/com.topjohnwu.magisk-1
          cp $DATABIN/magisk.apk /data/app/com.topjohnwu.magisk-1/base.apk
          chown 1000.1000 /data/app/com.topjohnwu.magisk-1
          chown 1000.1000 /data/app/com.topjohnwu.magisk-1/base.apk
          chmod 755 /data/app/com.topjohnwu.magisk-1
          chmod 644 /data/app/com.topjohnwu.magisk-1/base.apk
          chcon u:object_r:apk_data_file:s0 /data/app/com.topjohnwu.magisk-1
          chcon u:object_r:apk_data_file:s0 /data/app/com.topjohnwu.magisk-1/base.apk
        fi
        rm -f $DATABIN/magisk.apk 2>/dev/null
      fi

      # Expose busybox
      [ "`getprop persist.magisk.busybox`" = "1" ] && sh /sbin/magic_mask.sh mount_busybox

      # Restart post-fs-data if necessary (multirom)
      ($MULTIROM) && setprop magisk.restart_pfsd 1

    fi
    unblock
    ;;

  mount_busybox )
    log_print "* Enabling BusyBox"
    cp -afc /system/xbin/. $TOOLPATH
    umount /system/xbin 2>/dev/null
    bind_mount $TOOLPATH /system/xbin
    ;;

  service )
    # Version info
    MAGISK_VERSION_STUB
    log_print "** Magisk late_start service mode running..."
    if [ -f $DISABLEFILE ]; then
      setprop ro.magisk.disable 1
      exit
    fi
    run_scripts service
    
    # Start MagiskHide
    [ "`getprop persist.magisk.hide`" = "1" ] && sh $COREDIR/magiskhide/enable
    ;;

esac
