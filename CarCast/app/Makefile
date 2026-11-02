TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = CarCastSettings
CarCastSettings_FILES = ../../shared/SettingsApp/main.m CarCastSettings.m
CarCastSettings_FRAMEWORKS = UIKit
CarCastSettings_PRIVATE_FRAMEWORKS = Preferences
CarCastSettings_CFLAGS = -fobjc-arc -DXT_CARCAST
CarCastSettings_CODESIGN_FLAGS = -S../../shared/SettingsApp/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
