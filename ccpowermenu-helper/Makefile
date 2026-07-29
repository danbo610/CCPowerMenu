TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
SYSROOT = $(THEOS)/sdks/iPhoneOS14.2.sdk

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ccpowermenu-helper

ccpowermenu-helper_FILES = main.m
ccpowermenu-helper_CFLAGS = -fobjc-arc
ccpowermenu-helper_CODESIGN_FLAGS = -Sentitlements.plist
ccpowermenu-helper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

internal-stage::
	$(ECHO_NOTHING)chmod 6755 $(THEOS_STAGING_DIR)/usr/libexec/$(TOOL_NAME)$(ECHO_END)
