TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard CarPlay

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CarCast
CarCast_FILES = src/Log.m src/CCHost.m src/CarPlayHooks.x src/SpringBoardHooks.x src/AppHooks.x
CC_DEBUG ?= 0
CarCast_CFLAGS = -fobjc-arc -DCC_DEBUG=$(CC_DEBUG) -Wno-unused-function -Wno-deprecated-declarations
CarCast_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
