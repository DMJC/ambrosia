include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = ambrosia-compositor

ambrosia-compositor_OBJC_FILES = \
	main.m \
	AmbrosiaCompositor.m \
	AmbrosiaOutput.m \
	AmbrosiaView.m \
	AmbrosiaDecoration.m \
	AmbrosiaInput.m \
	AmbrosiaSession.m \
	AmbrosiaBackground.m

ambrosia-compositor_OBJCFLAGS = \
	$(shell pkg-config --cflags wlroots-0.20 wayland-server xkbcommon cairo) \
	-DWLR_USE_UNSTABLE \
	-I$(CURDIR)

ambrosia-compositor_LDFLAGS = \
	$(shell pkg-config --libs wlroots-0.20 wayland-server xkbcommon cairo) \
	-ldrm -ljpeg

ambrosia-compositor_INCLUDE_DIRS = .

# GNUstep 2.0 ARC runtime
OBJCFLAGS += -fobjc-arc

include $(GNUSTEP_MAKEFILES)/tool.make
