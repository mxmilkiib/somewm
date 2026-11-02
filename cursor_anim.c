/* The themed cursor's animation set: copies of an xcursor's frames as cairo
 * surfaces with their delays. Rebuilt when the displayed set or the seat's
 * image generation moves on; the render-side clock then swaps the realized
 * texture on a timer instead of forcing a declare per frame. */

#include <stdlib.h>
#include <string.h>
#include <cairo.h>
#include <wlr/xcursor.h>

#include "cursor_anim.h"

cairo_surface_t *
cursor_frame_surface(const struct wlr_xcursor_image *frame)
{
	cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
		frame->width, frame->height);
	int stride = cairo_image_surface_get_stride(s);
	unsigned char *dst = cairo_image_surface_get_data(s);

	if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS || !dst) {
		cairo_surface_destroy(s);
		return NULL;
	}
	cairo_surface_flush(s);
	for (uint32_t y = 0; y < frame->height; y++)
		memcpy(dst + y * stride, frame->buffer + (size_t)y * frame->width * 4,
			(size_t)frame->width * 4);
	cairo_surface_mark_dirty(s);
	return s;
}

void
cursor_anim_free(struct cursor_anim_set *set)
{
	for (size_t i = 0; i < set->len; i++)
		if (set->frames[i])
			cairo_surface_destroy(set->frames[i]);
	free(set->frames);
	free(set->delays);
	set->frames = NULL;
	set->delays = NULL;
	set->len = 0;
}

/* Frames that differ in size or hotspot stay a static first frame: the
 * leaf's box and hotspot are authored once per declare, and stepping them
 * would need the declare per frame this scheme exists to avoid. */
void
cursor_anim_build(struct cursor_anim_set *set, const struct wlr_xcursor *xc,
	uint64_t gen)
{
	if (set->xc == xc && set->gen == gen)
		return;
	cursor_anim_free(set);
	set->xc = xc;
	set->gen = gen;
	const struct wlr_xcursor_image *f0 = xc->images[0];
	for (uint32_t i = 1; i < xc->image_count; i++) {
		const struct wlr_xcursor_image *f = xc->images[i];
		if (f->width != f0->width || f->height != f0->height
				|| f->hotspot_x != f0->hotspot_x || f->hotspot_y != f0->hotspot_y)
			return;
	}
	set->frames = calloc(xc->image_count, sizeof(*set->frames));
	set->delays = malloc(xc->image_count * sizeof(*set->delays));
	if (!set->frames || !set->delays) {
		cursor_anim_free(set);
		return;
	}
	for (uint32_t i = 0; i < xc->image_count; i++) {
		set->frames[i] = cursor_frame_surface(xc->images[i]);
		set->delays[i] = xc->images[i]->delay;
		if (!set->frames[i]) {
			cursor_anim_free(set);
			return;
		}
	}
	set->len = xc->image_count;
}
