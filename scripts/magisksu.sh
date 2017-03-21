#!/system/bin/sh

MODDIR=${0%/*}
LOGFILE=/cache/magisk.log

log_print() {
  echo "MagiskSU: $1"
  echo "MagiskSU: $1" >> $LOGFILE
  log -p i -t Magisk "MagiskSU: $1"
}

log_print "Moving and linking /sbin binaries"
mount -o rw,remount rootfs /
cp -af /sbin /sbin_orig
mount -o ro,remount rootfs /

log_print "Exposing su binary"
rm -rf /magisk/.core/bin $MODDIR/sbin_bind
mkdir -p $MODDIR/sbin_bind
ln -s /sbin_orig/* $MODDIR/sbin_bind
chcon -h u:object_r:rootfs:s0 $MODDIR/sbin_bind/*
chmod 755 $MODDIR/sbin_bind
ln -s $MODDIR/su $MODDIR/sbin_bind/su
if [ -f "/data/magisk/magiskpolicy" ]; then
  ln -s /data/magisk/magiskpolicy $MODDIR/sbin_bind/magiskpolicy
else
  # legacy sepolicy-inject
  ln -s /data/magisk/sepolicy-inject $MODDIR/sbin_bind/sepolicy-inject
fi
ln -s /data/magisk/resetprop $MODDIR/sbin_bind/resetprop
mount -o bind $MODDIR/sbin_bind /sbin

log_print "Starting su daemon"
/sbin/su --daemon
