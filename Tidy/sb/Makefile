TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidySB
TidySB_FILES = Tweak.x ../core/TDCore.m
TidySB_CFLAGS = -fobjc-arc
TidySB_LIBRARIES = sqlite3
TidySB_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
