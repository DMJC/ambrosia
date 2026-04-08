include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = ambrosia-compositor

ambrosia-compositor_OBJC_FILES = \
	main.m \
	AmbrosiaCompositor.m \
	AmbrosiaOutput.m \
	AmbrosiaView.m \
	AmbrosiaDecoration.m \
	AmbrosiaInput.m

ambrosia-compositor_OBJCFLAGS = \
	$(shell pkg-config --cflags wlroots-0.20 wayland-server xkbcommon) \
	-DWLR_USE_UNSTABLE

ambrosia-compositor_LDFLAGS = \
	$(shell pkg-config --libs wlroots-0.20 wayland-server xkbcommon) \
	-ldrm

ambrosia-compositor_INCLUDE_DIRS = .

# GNUstep 2.0 ARC runtime
OBJCFLAGS += -fobjc-arc

include $(GNUSTEP_MAKEFILES)/tool.make
