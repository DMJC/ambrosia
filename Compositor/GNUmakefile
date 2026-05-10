include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = ambrosia-compositor

ambrosia-compositor_OBJC_FILES = \
	main.m \
	AmbrosiaCompositor.m \
	AmbrosiaOutput.m \
	AmbrosiaView.m \
	AmbrosiaXWaylandView.m \
	AmbrosiaDecoration.m \
	AmbrosiaInput.m \
	AmbrosiaSession.m \
	AmbrosiaBackground.m

ambrosia-compositor_OBJCFLAGS = \
	$(shell pkg-config --cflags wlroots-0.20 wayland-server xkbcommon cairo xcb xcb-icccm xcb-ewmh) \
	-DWLR_USE_UNSTABLE \
	-I$(CURDIR)

ambrosia-compositor_LDFLAGS = \
	$(shell pkg-config --libs wlroots-0.20 wayland-server xkbcommon cairo xcb xcb-icccm xcb-ewmh) \
	$(shell gnustep-config --gui-libs) \
	-ldrm -ljpeg

ambrosia-compositor_INCLUDE_DIRS = .

# GNUstep 2.0 ARC runtime
OBJCFLAGS += -fobjc-arc

include $(GNUSTEP_MAKEFILES)/tool.make
