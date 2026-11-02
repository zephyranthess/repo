TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LineFixPrefs
LineFixPrefs_FILES = LFRootListController.m
LineFixPrefs_FRAMEWORKS = UIKit
LineFixPrefs_PRIVATE_FRAMEWORKS = Preferences
LineFixPrefs_INSTALL_PATH = /Library/PreferenceBundles
LineFixPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
