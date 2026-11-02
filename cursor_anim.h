#ifndef SOMEWM_CURSOR_ANIM_H
#define SOMEWM_CURSOR_ANIM_H

#include <stddef.h>
#include <stdint.h>

struct wlr_xcursor;
struct wlr_xcursor_image;
typedef struct _cairo_surface cairo_surface_t;

/* An output's animation surfaces for one xcursor set: the frame rasters and
 * their millisecond delays, built once per (xcursor set, generation) and
 * handed to the render layer's clock, which steps the leaf's texture without
 * a declare per frame. */
struct cursor_anim_set {
	cairo_surface_t **frames;
	uint32_t *delays;
	size_t len;
	const struct wlr_xcursor *xc;
	uint64_t gen;
};

/* A copy of an xcursor frame's pixels: ARGB32 premultiplied in both. */
cairo_surface_t *cursor_frame_surface(const struct wlr_xcursor_image *frame);

void cursor_anim_free(struct cursor_anim_set *set);
void cursor_anim_build(struct cursor_anim_set *set,
	const struct wlr_xcursor *xc, uint64_t gen);

#endif
