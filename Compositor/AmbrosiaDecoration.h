#ifndef AMBROSIA_DECORATION_H
#define AMBROSIA_DECORATION_H

#import <Foundation/Foundation.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/render/wlr_renderer.h>

/* Decoration geometry constants — match Milk.theme dimensions */
#define AMBROSIA_TITLEBAR_HEIGHT  24   /* Milk TITLE_HEIGHT                          */
#define AMBROSIA_BORDER_WIDTH      4   /* frame hit-zone width; stroke is 1 px       */
#define AMBROSIA_BTN_SIZE         15   /* Milk TITLEBAR_BUTTON_SIZE                  */
#define AMBROSIA_BTN_PAD_SIDE     10   /* Milk TITLEBAR_PADDING_LEFT/RIGHT (rounded) */
#define AMBROSIA_BTN_PAD_TOP       5   /* Milk TITLEBAR_PADDING_TOP (rounded)        */

typedef NS_ENUM(NSInteger, AmbrosiaDecorationHit) {
    AmbrosiaDecorationHitNone = 0,
    AmbrosiaDecorationHitTitlebar,
    AmbrosiaDecorationHitClose,
    AmbrosiaDecorationHitMinimize,
    AmbrosiaDecorationHitMaximize,
    AmbrosiaDecorationHitResizeTop,
    AmbrosiaDecorationHitResizeBottom,
    AmbrosiaDecorationHitResizeLeft,
    AmbrosiaDecorationHitResizeRight,
    AmbrosiaDecorationHitResizeTopLeft,
    AmbrosiaDecorationHitResizeTopRight,
    AmbrosiaDecorationHitResizeBottomLeft,
    AmbrosiaDecorationHitResizeBottomRight,
};

@interface AmbrosiaDecoration : NSObject

/** Whether the associated window is focused */
@property (nonatomic) BOOL focused;
/** The parent scene tree (owned by the view) */
@property (nonatomic, readonly) struct wlr_scene_tree *scene_tree;

- (instancetype)initWithRenderer:(struct wlr_renderer *)renderer
                       sceneTree:(struct wlr_scene_tree *)parentTree;

/**
 * Update the decoration dimensions and title.
 * Call whenever the surface is mapped or resized.
 */
- (void)updateWithWidth:(int)surfaceWidth
                 height:(int)surfaceHeight
                  title:(NSString *)title;

/**
 * Override the Milk-theme default colours from a dictionary of RRGGBBAA hex strings.
 * Recognised keys: titlebarGradientTopColor, titlebarGradientBottomColor,
 * titlebarInactiveTopColor, titlebarInactiveBottomColor, titlebarSeparatorColor,
 * windowBorderColor, windowBodyColor, buttonActiveColor, buttonInactiveColor.
 * Missing keys retain their current value.
 */
- (void)updateColorsFromDictionary:(NSDictionary *)dict;

/**
 * Hit-test a compositor-space point (relative to this view's top-left,
 * i.e. top-left of the decoration frame).
 * Returns one of the AmbrosiaDecorationHit values.
 */
- (AmbrosiaDecorationHit)hitTestX:(double)x y:(double)y;

/**
 * Total decoration frame size around the client surface.
 * top = AMBROSIA_TITLEBAR_HEIGHT, others = AMBROSIA_BORDER_WIDTH.
 */
+ (NSEdgeInsets)frameInsets;

@end

#endif /* AMBROSIA_DECORATION_H */
