TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SpeedBoostPrefs
SpeedBoostPrefs_FILES = SBRootListController.m
SpeedBoostPrefs_FRAMEWORKS = UIKit
SpeedBoostPrefs_PRIVATE_FRAMEWORKS = Preferences
SpeedBoostPrefs_INSTALL_PATH = /Library/PreferenceBundles
SpeedBoostPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
