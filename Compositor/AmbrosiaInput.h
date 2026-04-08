#ifndef AMBROSIA_INPUT_H
#define AMBROSIA_INPUT_H

#import <Foundation/Foundation.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_pointer.h>
#include <xkbcommon/xkbcommon.h>

@class AmbrosiaCompositor;

struct ambrosia_keyboard_state {
    struct wlr_keyboard *keyboard;
    struct wl_listener modifiers;
    struct wl_listener key;
    struct wl_listener destroy;
    void *objc_input;
};

@interface AmbrosiaInput : NSObject

@property (nonatomic, weak) AmbrosiaCompositor *compositor;
@property (nonatomic, readonly) NSMutableArray *keyboards;

- (instancetype)initWithCompositor:(AmbrosiaCompositor *)compositor;

/** Add a new input device (keyboard or pointer) */
- (void)addDevice:(struct wlr_input_device *)device;

/** Handle a keyboard modifiers changed event */
- (void)handleKeyboardModifiersForState:(struct ambrosia_keyboard_state *)kbState;

/** Handle a keyboard key event; returns YES if compositor consumed it */
- (BOOL)handleKeyboardKeyForState:(struct ambrosia_keyboard_state *)kbState
                            event:(struct wlr_keyboard_key_event *)event;

@end

#endif /* AMBROSIA_INPUT_H */
