TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Tidy
Tidy_FILES = main.m TDViews.m TDControllers.m ../core/TDCore.m
Tidy_FRAMEWORKS = UIKit
Tidy_LIBRARIES = sqlite3
Tidy_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Tidy_CODESIGN_FLAGS = -S../../shared/SettingsApp/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
