TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpeedBoost
SpeedBoost_FILES = Tweak.x
SpeedBoost_CFLAGS = -fobjc-arc
SpeedBoost_FRAMEWORKS = QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += speedboostprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
