LOCAL_PATH := $(call my-dir)

include jni/bootimgtools/Android.mk
# include jni/magiskboot/Android.mk new
include jni/magiskhide/Android.mk
include jni/resetprop/Android.mk
include jni/magiskpolicy/Android.mk
# include jni/sepolicy-inject/Android.mk legacy
include jni/su/Android.mk

# include jni/selinux/libsepol/Android.mk legacy
# include jni/selinux/libselinux/Android.mk legacy
