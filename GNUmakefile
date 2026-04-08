# Root GNUmakefile — builds Compositor, Dock, and SystemPreferences pane.
#
# Prerequisites:
#   GNUstep make        (gnustep-make)
#   GNUstep base        (gnustep-base)
#   GNUstep gui/back    (gnustep-gui, gnustep-back with Wayland support)
#   wlroots >= 0.17     (libwlroots-dev)
#   wayland-server      (libwayland-dev)
#   xkbcommon           (libxkbcommon-dev)
#   cairo               (libcairo2-dev)
#   pixman              (libpixman-1-dev)
#   drm                 (libdrm-dev)
#
# Build:
#   source /usr/share/GNUstep/Makefiles/GNUstep.sh
#   make
#
# Install:
#   make install
#
# Run:
#   ambrosia-compositor
#   (AmbrosiaDock launches automatically from the compositor)

include $(GNUSTEP_MAKEFILES)/common.make

SUBPROJECTS = Compositor Dock SystemPreferences

include $(GNUSTEP_MAKEFILES)/aggregate.make

.PHONY: run clean-all

run: all
	./Compositor/$(GNUSTEP_OBJ_DIR)/ambrosia-compositor

clean-all:
	$(MAKE) -C Compositor clean
	$(MAKE) -C Dock clean
	$(MAKE) -C SystemPreferences clean
