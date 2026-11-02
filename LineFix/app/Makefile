TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = LineFixSettings
LineFixSettings_FILES = ../../shared/SettingsApp/main.m 
LineFixSettings_FRAMEWORKS = UIKit
LineFixSettings_PRIVATE_FRAMEWORKS = Preferences
LineFixSettings_CFLAGS = -fobjc-arc -DXT_PREFS_BUNDLE='"LineFixPrefs"' -DXT_PREFS_CLASS='"LFRootListController"' -DXT_TITLE='"LineFix"'
LineFixSettings_CODESIGN_FLAGS = -S../../shared/SettingsApp/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
