TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = XSTweaks
XSTweaks_FILES = main.m CarCastSettings.m
XSTweaks_FRAMEWORKS = UIKit
XSTweaks_PRIVATE_FRAMEWORKS = Preferences
XSTweaks_CFLAGS = -fobjc-arc
XSTweaks_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
