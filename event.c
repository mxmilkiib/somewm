/*
 * event.c - event handling helpers
 *
 * Adapted from AwesomeWM's event.c for somewm (Wayland compositor)
 * Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "event.h"
#include "event_queue.h"
#include "globalconf.h"
#include "objects/mousegrabber.h"
#include "somewm_api.h"
#include "luaa.h"
#include "common/luaobject.h"
#include <stdio.h>
#include <time.h>

/* Motion events reaching an active mousegrabber are coalesced to the latest
 * position before delivery. X11 already folds MotionNotify this way, which is
 * the rate awesome's synchronous callback was written for; Wayland hands us
 * every device event instead, so a fast pointer can out-poll the frame rate
 * and run the whole Lua move path many times inside one frame. The stash is
 * flushed once per output frame (declare.c) or after GRABBER_FLUSH_US,
 * whichever comes first. */
#define GRABBER_FLUSH_US 8000

static bool grabber_pending;
static int grabber_x, grabber_y;
static int64_t grabber_us;

static int64_t
grabber_now_us(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void
grabber_run(int x, int y, uint16_t mask)
{
    lua_State *L = globalconf_get_lua_State();

    /* Push coords table to stack */
    mousegrabber_handleevent(L, (int)x, (int)y, mask);

    /* Get mousegrabber callback */
    lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

    /* Push coords as argument */
    lua_pushvalue(L, -2);

    /* Call callback(coords) */
    if (lua_pcall(L, 1, 1, 0) == 0) {
        /* Check return value */
        if (!lua_isboolean(L, -1) || !lua_toboolean(L, -1)) {
            /* Callback returned false - stop grabbing */
            luaA_mousegrabber_stop(L);
        }
        lua_pop(L, 1);  /* Pop return value */
    } else {
        /* Error in callback - stop grabbing */
        fprintf(stderr, "somewm: mousegrabber error: %s\n",
                lua_tostring(L, -1));
        lua_pop(L, 1);  /* Pop error message */
        luaA_mousegrabber_stop(L);
    }

    lua_pop(L, 1);  /* Pop coords table */
}

/** Deliver the stashed motion to the grabber, once, with the freshest button
 * state. Called by the frame (declare.c) and, as a starvation fallback, by
 * the refresh cycle when the stash goes stale. */
void
event_grabber_flush(void)
{
    if (!grabber_pending)
        return;
    grabber_pending = false;
    if (mousegrabber_isrunning())
        grabber_run(grabber_x, grabber_y, some_button_state_mask());
}

/* Deliver the stash only when it has waited longer than GRABBER_FLUSH_US:
 * a grabber that never dirties the screen still hears motion, bounded. */
void
event_grabber_flush_stale(void)
{
    if (grabber_pending && grabber_now_us() - grabber_us >= GRABBER_FLUSH_US)
        event_grabber_flush();
}

/* Drop any stashed motion without delivering it (grab released/reloaded). */
void
event_grabber_cancel(void)
{
    grabber_pending = false;
}

/** A motion event while a grab is active is stashed for the next flush
 * instead of running the Lua callback per event.
 * \return true if the grabber consumed it
 */
bool
event_handle_mousegrabber_motion(double x, double y)
{
    if (!mousegrabber_isrunning())
        return false;

    grabber_x = (int)x;
    grabber_y = (int)y;
    if (!grabber_pending)
        grabber_us = grabber_now_us();
    grabber_pending = true;
    return true;
}

/** Handle event with mousegrabber if active
 * Ported from AwesomeWM's event_handle_mousegrabber()
 *
 * The mask passed to the grabber is built from the tracked button state;
 * extra_mask bits are ORed in. Scroll buttons (4-7) are synthesized from
 * axis events and never held, so they only ever arrive via extra_mask.
 *
 * \param x Mouse X coordinate
 * \param y Mouse Y coordinate
 * \param extra_mask X11-style button mask bits to add to the tracked state
 * \return true if event consumed by mousegrabber
 */
bool
event_handle_mousegrabber(double x, double y, uint16_t extra_mask)
{
    uint16_t mask;

    if (!mousegrabber_isrunning())
        return false;

    /* A stashed motion precedes this event: deliver it first. Its callback
     * may end the grab (release seen in the live mask), leaving nothing to
     * call for this event. */
    event_grabber_flush();
    if (!mousegrabber_isrunning())
        return true;

    mask = extra_mask | some_button_state_mask();
    grabber_run((int)x, (int)y, mask);
    return true;
}

/** Deliver scroll ticks to the mousegrabber as X11-style button events.
 *
 * X11 delivers each tick as a press+release pair: the button's state mask
 * bit set, then cleared. Only buttons 1-5 have a state mask bit, so
 * horizontal ticks (buttons 6/7) set no flag, matching upstream.
 *
 * \param x Mouse X coordinate
 * \param y Mouse Y coordinate
 * \param button X11 button number (4-7)
 * \param ticks Number of full scroll ticks to deliver
 */
void
event_handle_mousegrabber_scroll(double x, double y, uint32_t button, int ticks)
{
    uint16_t press_mask = button <= 5 ? 1 << (7 + button) : 0;

    for (int tick = 0; tick < ticks; tick++) {
        if (!event_handle_mousegrabber(x, y, press_mask))
            break;
        if (!event_handle_mousegrabber(x, y, 0))
            break;
    }
}

/** Record that the given drawable contains the pointer.
 * Emits mouse::enter/leave signals on drawables for widget hover events.
 */
void
event_drawable_under_mouse(lua_State *L, int ud)
{
	void *d;

	/* luaA_object_ref pops, so push a copy first */
	lua_pushvalue(L, ud);
	d = luaA_object_ref(L, -1);

	if (d == globalconf.drawable_under_mouse) {
		luaA_object_unref(L, d);
		return;
	}

	if (globalconf.drawable_under_mouse != NULL) {
		luaA_object_push(L, globalconf.drawable_under_mouse);
		some_event_queue_signal0(L, -1, SIG_MOUSE_LEAVE);
		lua_pop(L, 1);
		luaA_object_unref(L, globalconf.drawable_under_mouse);
		globalconf.drawable_under_mouse = NULL;
	}

	if (d != NULL) {
		globalconf.drawable_under_mouse = d;
		some_event_queue_signal0(L, ud, SIG_MOUSE_ENTER);
	}
}
