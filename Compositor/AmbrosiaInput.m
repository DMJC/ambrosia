#import "AmbrosiaInput.h"
#import "AmbrosiaCompositor.h"
#import "AmbrosiaView.h"

#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/backend/session.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

/* --------------------------------------------------------------------------
 * C callbacks for keyboard
 * -------------------------------------------------------------------------- */

static void handle_keyboard_modifiers(struct wl_listener *listener, void *data)
{
    struct ambrosia_keyboard_state *ks =
        wl_container_of(listener, ks, modifiers);
    AmbrosiaInput *input = (__bridge AmbrosiaInput *)ks->objc_input;
    [input handleKeyboardModifiersForState:ks];
}

static void handle_keyboard_key(struct wl_listener *listener, void *data)
{
    struct ambrosia_keyboard_state *ks =
        wl_container_of(listener, ks, key);
    AmbrosiaInput *input = (__bridge AmbrosiaInput *)ks->objc_input;
    [input handleKeyboardKeyForState:ks event:(struct wlr_keyboard_key_event *)data];
}

static void handle_keyboard_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_keyboard_state *ks =
        wl_container_of(listener, ks, destroy);
    AmbrosiaInput *input = (__bridge AmbrosiaInput *)ks->objc_input;
    /* Remove from list */
    for (NSValue *v in [input.keyboards copy]) {
        struct ambrosia_keyboard_state *s =
            (struct ambrosia_keyboard_state *)[v pointerValue];
        if (s == ks) {
            [input.keyboards removeObject:v];
            break;
        }
    }
    wl_list_remove(&ks->modifiers.link);
    wl_list_remove(&ks->key.link);
    wl_list_remove(&ks->destroy.link);
    free(ks);
}

/* --------------------------------------------------------------------------
 * AmbrosiaInput
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaInput {
    NSMutableArray *_keyboards;
}

@synthesize compositor = _compositor;

- (NSMutableArray *)keyboards { return _keyboards; }

- (instancetype)initWithCompositor:(AmbrosiaCompositor *)compositor
{
    self = [super init];
    if (!self) return nil;
    _compositor = compositor;
    _keyboards  = [NSMutableArray array];
    return self;
}

- (void)addDevice:(struct wlr_input_device *)device
{
    switch (device->type) {
        case WLR_INPUT_DEVICE_KEYBOARD:
            [self addKeyboard:wlr_keyboard_from_input_device(device)];
            break;
        case WLR_INPUT_DEVICE_POINTER:
            wlr_cursor_attach_input_device(_compositor.state->cursor, device);
            break;
        default:
            break;
    }
}

- (void)addKeyboard:(struct wlr_keyboard *)keyboard
{
    /* xkb keymap */
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap  *keymap  = xkb_keymap_new_from_names(
        context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    wlr_keyboard_set_keymap(keyboard, keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);

    wlr_keyboard_set_repeat_info(keyboard, 25, 600);

    struct ambrosia_keyboard_state *ks =
        calloc(1, sizeof(struct ambrosia_keyboard_state));
    ks->keyboard  = keyboard;
    ks->objc_input = (__bridge void *)self;

    ks->modifiers.notify = handle_keyboard_modifiers;
    wl_signal_add(&keyboard->events.modifiers, &ks->modifiers);

    ks->key.notify = handle_keyboard_key;
    wl_signal_add(&keyboard->events.key, &ks->key);

    ks->destroy.notify = handle_keyboard_destroy;
    wl_signal_add(&keyboard->base.events.destroy, &ks->destroy);

    [_keyboards addObject:[NSValue valueWithPointer:ks]];

    wlr_seat_set_keyboard(_compositor.state->seat, keyboard);
}

- (void)handleKeyboardModifiersForState:(struct ambrosia_keyboard_state *)ks
{
    wlr_seat_set_keyboard(_compositor.state->seat, ks->keyboard);
    wlr_seat_keyboard_notify_modifiers(_compositor.state->seat,
                                       &ks->keyboard->modifiers);
}

- (BOOL)handleKeyboardKeyForState:(struct ambrosia_keyboard_state *)ks
                            event:(struct wlr_keyboard_key_event *)event
{
    struct wlr_seat *seat   = _compositor.state->seat;
    struct wlr_keyboard *kb = ks->keyboard;

    /* Translate to xkb keysym */
    uint32_t keycode = event->keycode + 8;
    const xkb_keysym_t *syms;
    int nsyms = xkb_state_key_get_syms(kb->xkb_state, keycode, &syms);

    BOOL handled = NO;
    uint32_t modifiers = wlr_keyboard_get_modifiers(kb);

    for (int i = 0; i < nsyms; i++) {
        /* Ctrl+Alt+Backspace → save session and quit compositor */
        if (syms[i] == XKB_KEY_BackSpace
                && (modifiers & WLR_MODIFIER_CTRL) && (modifiers & WLR_MODIFIER_ALT)
                && event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
            wlr_log(WLR_INFO, "Ctrl+Alt+Backspace: saving session and stopping compositor");
            [_compositor saveSessionAndLogout];
            handled = YES;
        }
        /* Ctrl+Alt+F1–F12 → switch VTY.
         * xkb folds the Ctrl+Alt+Fn combo into XKB_KEY_XF86Switch_VT_N,
         * so we match on that keysym rather than Fn + modifier flags. */
        if (event->state == WL_KEYBOARD_KEY_STATE_PRESSED
                && syms[i] >= XKB_KEY_XF86Switch_VT_1
                && syms[i] <= XKB_KEY_XF86Switch_VT_12) {
            unsigned vt = syms[i] - XKB_KEY_XF86Switch_VT_1 + 1;
            struct wlr_session *session = _compositor.state->wlr_session;
            if (session) {
                wlr_log(WLR_INFO, "Switching to VT %u", vt);
                wlr_session_change_vt(session, vt);
            } else {
                wlr_log(WLR_DEBUG, "VT switch requested but no session available (nested compositor?)");
            }
            handled = YES;
        }
        /* Alt+F4 → close focused window */
        if (syms[i] == XKB_KEY_F4 && (modifiers & WLR_MODIFIER_ALT)
                && !(modifiers & WLR_MODIFIER_CTRL)) {
            if (_compositor.focusedView) {
                wlr_xdg_toplevel_send_close(
                    _compositor.focusedView.state->xdg_toplevel);
            }
            handled = YES;
        }
        /* Alt+Tab → cycle windows */
        if (syms[i] == XKB_KEY_Tab && (modifiers & WLR_MODIFIER_ALT)
                && !(modifiers & WLR_MODIFIER_LOGO)
                && event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
            [self cycleWindows];
            handled = YES;
        }
        /* Super+Tab → cycle applications */
        if (syms[i] == XKB_KEY_Tab && (modifiers & WLR_MODIFIER_LOGO)
                && !(modifiers & WLR_MODIFIER_ALT)
                && event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
            [self cycleApplications];
            handled = YES;
        }
    }

    if (!handled) {
        wlr_seat_set_keyboard(seat, kb);
        wlr_seat_keyboard_notify_key(seat, event->time_msec,
                                     event->keycode, event->state);
    }

    return handled;
}

- (void)cycleWindows
{
    NSArray<AmbrosiaView *> *views = _compositor.views;
    if (views.count < 2) return;

    /* Focus the view one below the current focused view */
    NSInteger idx = [views indexOfObject:_compositor.focusedView];
    if (idx == NSNotFound || idx == 0)
        idx = views.count - 1;
    else
        idx--;

    AmbrosiaView *next = views[idx];
    if (next.isMapped)
        [_compositor focusView:next surface:next.surface];
}

/**
 * Super+Tab: cycle keyboard focus across distinct applications.
 *
 * Applications are identified by their wl_client pointer — all windows
 * belonging to one process share the same client.  We build an ordered list
 * of unique clients (preserving the z-order of their topmost window), find
 * the client after the currently focused one, and give focus to the topmost
 * mapped, non-miniaturised window of that next client.
 */
- (void)cycleApplications
{
    NSArray<AmbrosiaView *> *views = _compositor.views;
    if (views.count < 2) return;

    /* Collect eligible views (mapped, non-menu, non-miniaturized). */
    NSMutableArray<AmbrosiaView *> *eligible = [NSMutableArray array];
    for (AmbrosiaView *v in views) {
        if (!v.isMapped)      continue;
        if (v.isMiniaturized) continue;
        if (v.isMenu)         continue;
        [eligible addObject:v];
    }
    if (eligible.count < 2) return;

    /*
     * Build an ordered list of unique wl_clients, preserving the z-order of
     * the last (topmost) window seen for each client.  Iterating eligible in
     * forward order means later entries overwrite earlier ones, so the final
     * array entry for each client reflects its topmost window.
     */
    NSMutableOrderedSet *clientOrder = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSValue *, AmbrosiaView *> *topmostForClient =
        [NSMutableDictionary dictionary];

    for (AmbrosiaView *v in eligible) {
        struct wl_client *client =
            wl_resource_get_client(v.state->xdg_toplevel->base->resource);
        NSValue *key = [NSValue valueWithPointer:client];
        [clientOrder addObject:key];           /* no-op if already present */
        topmostForClient[key] = v;             /* keeps the last/topmost window */
    }

    if (clientOrder.count < 2) return;        /* all windows belong to one app */

    /* Find the wl_client of the currently focused view. */
    struct wl_client *focusedClient = NULL;
    if (_compositor.focusedView) {
        focusedClient = wl_resource_get_client(
            _compositor.focusedView.state->xdg_toplevel->base->resource);
    }

    NSValue *focusedKey = focusedClient
        ? [NSValue valueWithPointer:focusedClient] : nil;
    NSUInteger currentIdx = focusedKey
        ? [clientOrder indexOfObject:focusedKey] : NSNotFound;

    /* Advance to the next client in the ordered set, wrapping around. */
    NSUInteger nextIdx;
    if (currentIdx == NSNotFound || currentIdx + 1 >= clientOrder.count)
        nextIdx = 0;
    else
        nextIdx = currentIdx + 1;

    NSValue *nextKey = clientOrder[nextIdx];
    AmbrosiaView *target = topmostForClient[nextKey];
    if (target)
        [_compositor focusView:target surface:target.surface];
}

@end
