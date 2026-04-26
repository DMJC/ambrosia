#ifndef AMBROSIA_XWAYLAND_VIEW_H
#define AMBROSIA_XWAYLAND_VIEW_H

#import <Foundation/Foundation.h>
#import "AmbrosiaWindowView.h"
#include <wlr/xwayland.h>
#include <wlr/types/wlr_scene.h>

@class AmbrosiaCompositor;
@class AmbrosiaDecoration;

struct ambrosia_xwayland_view_state {
    struct wlr_xwayland_surface *xwayland_surface;
    struct wlr_scene_tree       *scene_tree;    /* NULL until associate fires */

    /* xwayland_surface-level listeners (registered at init, removed at destroy) */
    struct wl_listener associate;
    struct wl_listener dissociate;
    struct wl_listener request_configure;
    struct wl_listener request_move;
    struct wl_listener request_resize;
    struct wl_listener request_minimize;
    struct wl_listener request_fullscreen;
    struct wl_listener request_activate;
    struct wl_listener request_close;
    struct wl_listener set_title;
    struct wl_listener set_class;
    struct wl_listener set_override_redirect;
    struct wl_listener destroy;

    /* wlr_surface-level listeners (registered on associate, removed on dissociate) */
    struct wl_listener surface_map;
    struct wl_listener surface_unmap;

    BOOL surface_listeners_active;

    void *objc_view;
};

@interface AmbrosiaXWaylandView : NSObject <AmbrosiaWindowView>

@property (nonatomic, weak)   AmbrosiaCompositor *compositor;
@property (nonatomic, readonly) struct ambrosia_xwayland_view_state *state;
@property (nonatomic, strong, nullable) AmbrosiaDecoration *decoration;

@property (nonatomic) int  x;
@property (nonatomic) int  y;
@property (nonatomic, readonly) BOOL isMapped;
@property (nonatomic, readonly) BOOL isMiniaturized;
@property (nonatomic, readonly) BOOL isFullscreen;
@property (nonatomic, readonly) BOOL isMenu;
@property (nonatomic, readonly) BOOL isDockWindow;
@property (nonatomic, readonly) BOOL isDesktopBackground;

- (instancetype)initWithXWaylandSurface:(struct wlr_xwayland_surface *)xsurface
                             compositor:(AmbrosiaCompositor *)compositor;

/* AmbrosiaWindowView protocol */
- (nullable struct wlr_surface *)surface;
- (struct wlr_box)geometry;
- (void)moveTo:(int)x y:(int)y;
- (void)miniaturize;
- (void)deminiaturize;
- (void)toggleFullscreen;
- (void)updateTitle;
- (void)activateFocus:(BOOL)focused;
- (void)close;
- (void)raiseSceneNode;
- (nullable struct wlr_surface *)surfaceAt:(double)x y:(double)y
                                   localX:(double *)lx localY:(double *)ly;
- (nullable struct wl_client *)waylandClient;
- (pid_t)clientPid;

/* Decoration management */
- (void)attachDecorationWithRenderer:(struct wlr_renderer *)renderer
                              colors:(nullable NSDictionary *)colors;
- (void)removeDecoration;

/* Callbacks invoked from C listeners */
- (void)handleAssociate;
- (void)handleDissociate;
- (void)handleMap;
- (void)handleUnmap;
- (void)handleDestroy;
- (void)handleRequestConfigure:(struct wlr_xwayland_surface_configure_event *)event;
- (void)handleRequestMove;
- (void)handleRequestResize:(uint32_t)edges;
- (void)handleRequestMinimize:(BOOL)minimize;
- (void)handleRequestFullscreen;
- (void)handleRequestActivate;
- (void)handleRequestClose;
- (void)handleSetTitle;
- (void)handleSetOverrideRedirect;

@end

#endif /* AMBROSIA_XWAYLAND_VIEW_H */
