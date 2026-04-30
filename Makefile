TARGET := iphone:clang:latest:14.0
ARCHS := arm64

INSTALL_TARGET_PROCESSES = discover

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XHS778
XHS778_FILES = Tweak.xm
XHS778_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
XHS778_FRAMEWORKS = UIKit Foundation Photos ImageIO MobileCoreServices

include $(THEOS_MAKE_PATH)/tweak.mk
