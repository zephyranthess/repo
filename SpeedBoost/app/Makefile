TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SpeedBoostSettings
SpeedBoostSettings_FILES = ../../shared/SettingsApp/main.m 
SpeedBoostSettings_FRAMEWORKS = UIKit
SpeedBoostSettings_PRIVATE_FRAMEWORKS = Preferences
SpeedBoostSettings_CFLAGS = -fobjc-arc -DXT_PREFS_BUNDLE='"SpeedBoostPrefs"' -DXT_PREFS_CLASS='"SBRootListController"' -DXT_TITLE='"SpeedBoost"'
SpeedBoostSettings_CODESIGN_FLAGS = -S../../shared/SettingsApp/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
