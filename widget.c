/*
 * widget.c - the widget tree lua/wibox/clay.lua compiles
 *
 * lua/wibox/clay.lua walks a drawable's widget tree and describes what Clay
 * can solve as a tree of nodes, with every subtree it cannot express as a
 * raster leaf. This file reads that description off the Lua stack, stores it
 * on the drawin, and owns the leaf surfaces Lua draws into. It holds no Clay:
 * declaring the tree is declare.c's and drawing it is the renderer's, so a
 * node here is nothing but the numbers Lua handed over.
 */

#include <string.h>

#include <lauxlib.h>

#include "luaa.h"

#include "widget.h"
#include "common/util.h"
#include "declare.h"
#include "globalconf.h"
#include "monitor.h"
#include "render.h"
#include "render_text.h"
#include "objects/drawable.h"
#include "objects/drawin.h"
#include "objects/screen.h"

/* A four-number array field (pad, bw, bg, border), left at zero when the
 * field is absent. False for a field that is present but not four numbers,
 * which is a compile-step bug rather than a config to ride out. */
static bool
read_quad(lua_State *L, int idx, const char *name, float *out)
{
	bool ok = true;

	lua_getfield(L, idx, name);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return true;
	}
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return false;
	}
	for (int i = 0; i < 4; i++) {
		lua_rawgeti(L, -1, i + 1);
		if (lua_isnumber(L, -1))
			out[i] = (float)lua_tonumber(L, -1);
		else
			ok = false;
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return ok;
}

/* An optional number field inside a range, false for one outside it or of
 * the wrong type. Refusing rather than raising is what lets a malformed
 * tree fall back to painting whole: an error here unwinds through the
 * redraw that already dropped its dirty region, leaving the last tree
 * declared and nothing repainting it. */
static bool
read_number(lua_State *L, int idx, const char *name, double min, double max,
	float *out)
{
	bool ok;

	lua_getfield(L, idx, name);
	if (lua_isnumber(L, -1)) {
		double v = lua_tonumber(L, -1);

		ok = v >= min && v <= max;
		*out = (float)v;
	} else {
		ok = lua_isnil(L, -1);
	}
	lua_pop(L, 1);
	return ok;
}

/* One axis of sizing, as Clay names it: "fit" or absent for
 * CLAY_SIZING_FIT, Clay's default (README, clay.h:290), "grow" for
 * CLAY_SIZING_GROW, a number for CLAY_SIZING_FIXED. */
static bool
read_sizing(lua_State *L, int idx, const char *name, uint8_t *sizing,
	float *size)
{
	const char *s;
	bool ok = true;

	lua_getfield(L, idx, name);
	if (lua_type(L, -1) == LUA_TNUMBER) {
		*sizing = WIDGET_SIZING_FIXED;
		*size = (float)lua_tonumber(L, -1);
		ok = *size >= 0;
	} else if (lua_isnil(L, -1)) {
		*sizing = WIDGET_SIZING_FIT;
	} else if ((s = lua_tostring(L, -1)) && strcmp(s, "fit") == 0) {
		*sizing = WIDGET_SIZING_FIT;
	} else if (s && strcmp(s, "grow") == 0) {
		*sizing = WIDGET_SIZING_GROW;
	} else {
		ok = false;
	}
	lua_pop(L, 1);
	return ok;
}

/* Child alignment on one axis, named as wibox.container.place names it, as
 * Clay's own enum value: Clay_LayoutAlignmentX and Y both order their
 * enumerators start, end, center. */
static bool
read_align(lua_State *L, int idx, const char *name, uint8_t *out)
{
	const char *s;
	bool ok = true;

	lua_getfield(L, idx, name);
	s = lua_tostring(L, -1);
	if (!s || strcmp(s, "left") == 0 || strcmp(s, "top") == 0)
		*out = 0;
	else if (strcmp(s, "right") == 0 || strcmp(s, "bottom") == 0)
		*out = 1;
	else if (strcmp(s, "center") == 0)
		*out = 2;
	else
		ok = false;
	lua_pop(L, 1);
	return ok;
}

/* The class names seen so far, interned so a node holds a stable pointer and
 * the tree still compares by memcmp. A config names a couple of dozen widget
 * classes and never frees one, so the table only grows, by a pointer each. */
static const char *
intern_class(const char *name)
{
	static const char **names;
	static size_t len, cap;

	for (size_t i = 0; i < len; i++)
		if (strcmp(names[i], name) == 0)
			return names[i];
	if (len == cap) {
		cap = cap ? cap * 2 : 32;
		p_realloc(&names, cap);
	}
	return names[len++] = a_strdup(name);
}

/* One of a small set of words, as the index of the Clay enumerator it names,
 * false for any other value. */
static bool
read_word(lua_State *L, int idx, const char *name, const char *const *words,
	size_t count, uint8_t *out)
{
	const char *s;
	bool ok = false;

	lua_getfield(L, idx, name);
	s = lua_tostring(L, -1);
	for (size_t i = 0; s && i < count; i++) {
		if (strcmp(s, words[i]) == 0) {
			*out = (uint8_t)i;
			ok = true;
		}
	}
	lua_pop(L, 1);
	return ok;
}

/* The scratch text buffer a tree is read into, alongside the scratch nodes:
 * a redraw reads into both and usually finds the stored tree unchanged. */
static char text_buf[WIDGET_TEXT_MAX];
static size_t text_len;

/* A text node: the run, appended to the scratch text, and its config, in
 * Clay's own words (Clay_TextElementConfigWrapMode, Clay_TextAlignment). */
static bool
read_text(lua_State *L, int idx, struct widget_node *n)
{
	static const char *const wraps[] = { "words", "newlines", "none" };
	static const char *const aligns[] = { "left", "center", "right" };
	size_t len;
	const char *text;
	float font = 0;
	bool ok;

	lua_getfield(L, idx, "text");
	text = lua_tolstring(L, -1, &len);
	if (!text || len > WIDGET_TEXT_MAX - text_len) {
		lua_pop(L, 1);
		return false;
	}
	memcpy(text_buf + text_len, text, len);
	n->text = true;
	n->text_off = (uint32_t)text_len;
	n->text_len = (uint32_t)len;
	text_len += len;
	lua_pop(L, 1);

	ok = read_number(L, idx, "font", 0, UINT16_MAX, &font)
		&& read_quad(L, idx, "color", n->fg)
		&& read_word(L, idx, "wrap", wraps, 3, &n->wrap)
		&& read_word(L, idx, "halign", aligns, 3, &n->text_align);
	n->font = (uint16_t)font;
	lua_getfield(L, idx, "ellipsize");
	n->ellipsize = lua_toboolean(L, -1);
	lua_pop(L, 1);
	return ok;
}

static bool
read_node(lua_State *L, int idx, struct widget_node *n)
{
	float pad[4] = { 0 }, bw[4] = { 0 }, gap = 0;
	const char *dir;
	bool ok;

	if (!lua_istable(L, idx))
		return false;
	lua_getfield(L, idx, "class");
	if (lua_isstring(L, -1))
		n->cls = intern_class(lua_tostring(L, -1));
	lua_pop(L, 1);
	lua_getfield(L, idx, "text");
	ok = lua_isnil(L, -1);
	lua_pop(L, 1);
	if (!ok)
		return read_text(L, idx, n);
	if (!read_quad(L, idx, "pad", pad) || !read_quad(L, idx, "bw", bw)
			|| !read_quad(L, idx, "bg", n->bg)
			|| !read_quad(L, idx, "border", n->border))
		return false;
	for (int i = 0; i < 4; i++) {
		if (pad[i] < 0 || pad[i] > UINT16_MAX
				|| bw[i] < 0 || bw[i] > UINT16_MAX)
			return false;
		n->pad[i] = (uint16_t)pad[i];
		n->bw[i] = (uint16_t)bw[i];
	}

	if (!read_number(L, idx, "radius", 0, 1e6, &n->radius)
			|| !read_number(L, idx, "gap", 0, UINT16_MAX, &gap)
			|| !read_number(L, idx, "wmin", 0, 1e6, &n->min[0])
			|| !read_number(L, idx, "hmin", 0, 1e6, &n->min[1])
			|| !read_number(L, idx, "wmax", 0, 1e6, &n->max[0])
			|| !read_number(L, idx, "hmax", 0, 1e6, &n->max[1]))
		return false;
	n->gap = (uint16_t)gap;
	if (!read_sizing(L, idx, "w", &n->sizing[0], &n->size[0])
			|| !read_sizing(L, idx, "h", &n->sizing[1], &n->size[1]))
		return false;

	lua_getfield(L, idx, "align");
	ok = lua_isnil(L, -1) || (lua_istable(L, -1)
		&& read_align(L, lua_gettop(L), "x", &n->align[0])
		&& read_align(L, lua_gettop(L), "y", &n->align[1]));
	lua_pop(L, 1);

	lua_getfield(L, idx, "dir");
	dir = lua_tostring(L, -1);
	n->vertical = dir && strcmp(dir, "y") == 0;
	lua_pop(L, 1);

	lua_getfield(L, idx, "float");
	n->floating = lua_toboolean(L, -1);
	lua_pop(L, 1);
	lua_getfield(L, idx, "raster");
	n->raster = lua_toboolean(L, -1);
	lua_pop(L, 1);
	lua_getfield(L, idx, "image");
	if (lua_islightuserdata(L, -1)) {
		n->image = lua_touserdata(L, -1);
		n->raster = true;
	} else if (!lua_isnil(L, -1)) {
		ok = false;
	}
	lua_pop(L, 1);
	if (n->image && !read_number(L, idx, "aspect", 0, 1e6, &n->aspect))
		ok = false;
	lua_getfield(L, idx, "spacer");
	n->widget = !lua_toboolean(L, -1);
	lua_pop(L, 1);

	return ok;
}

/* The subtree rooted at the table at idx, in preorder, into nodes. A leaf
 * has no children; anything else lists them under `children`. clip_by is
 * the scope the subtree sits in, and clips counts the scopes opened so far
 * (widget.h clip_opens): the root opens one, and so does a rounded node
 * with children. Past WIDGET_CLIPS_MAX, clips is left one over and the tree
 * is refused. */
static bool
read_tree(lua_State *L, int idx, struct widget_node *nodes, size_t *len,
	size_t *leaves, unsigned clip_by, unsigned *clips)
{
	struct widget_node *n;
	size_t count;
	bool ok;

	/* Two slots per level are live across the recursion (the children
	 * table and the child), plus what read_node needs at the bottom; a C
	 * function is only guaranteed LUA_MINSTACK. */
	if (*len == WIDGET_NODES_MAX || !lua_checkstack(L, 4))
		return false;
	n = &nodes[(*len)++];
	memset(n, 0, sizeof(*n));
	if (!read_node(L, idx, n))
		return false;
	if (n->raster)
		(*leaves)++;
	n->clip_by = (uint8_t)clip_by;

	lua_getfield(L, idx, "children");
	ok = lua_isnil(L, -1) || (lua_istable(L, -1) && !n->raster && !n->text);
	count = ok ? luaA_rawlen(L, -1) : 0;
	n->children = (uint16_t)count;
	if (ok && (*len == 1 || (n->radius > 0 && count > 0))) {
		if (*clips == WIDGET_CLIPS_MAX)
			ok = false;
		n->clip_opens = (uint8_t)++*clips;
		clip_by = n->clip_opens;
	}
	for (size_t i = 0; ok && i < count; i++) {
		lua_rawgeti(L, -1, (int)i + 1);
		ok = read_tree(L, lua_gettop(L), nodes, len, leaves, clip_by, clips);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return ok;
}

/* The leaf array at the tree's leaf count, surfaces kept where the index
 * survives: a leaf keeps its surface by its index in the tree, and
 * widget_leaves_size resizes the ones whose box changed. */
static void
leaves_count(drawin_t *d, size_t count)
{
	if (count == d->widget_leaves_len)
		return;
	for (size_t i = count; i < d->widget_leaves_len; i++)
		image_entry_set(&d->widget_leaves[i], NULL);
	p_realloc(&d->widget_leaves, count);
	if (count > d->widget_leaves_len)
		memset(&d->widget_leaves[d->widget_leaves_len], 0,
			(count - d->widget_leaves_len) * sizeof(*d->widget_leaves));
	d->widget_leaves_len = count;
}

void
widget_leaves_size(drawin_t *d, int (*dev)[2])
{
	size_t leaf = 0, sized = 0;

	for (size_t i = 0; i < d->widget_nodes_len; i++) {
		const struct widget_node *n = &d->widget_nodes[i];
		struct image_entry *entry;
		int w, h;

		if (!n->raster)
			continue;
		entry = &d->widget_leaves[leaf++];
		/* The widget's own surface: referenced, and a new reference only
		 * when it is another surface, so its generation moves with it. */
		if (n->image) {
			cairo_surface_t *surface = (cairo_surface_t *)n->image;

			if (entry->native != surface)
				image_entry_set(entry, cairo_surface_reference(surface));
			continue;
		}
		w = MAX(1, dev[sized][0]);
		h = MAX(1, dev[sized][1]);
		sized++;
		if (entry->native && entry->width == w && entry->height == h)
			continue;
		image_entry_set(entry, cairo_image_surface_create(
			CAIRO_FORMAT_ARGB32, w, h));
		entry->fresh = true;
	}
}

void
widget_nodes_clear(drawin_t *d)
{
	for (size_t i = 0; i < d->widget_leaves_len; i++)
		image_entry_set(&d->widget_leaves[i], NULL);
	p_delete(&d->widget_leaves);
	d->widget_leaves_len = 0;
	p_delete(&d->widget_nodes);
	d->widget_nodes_len = 0;
	p_delete(&d->widget_text);
	d->widget_text_len = 0;
	d->widget_nodes_declared = false;
}

unsigned
widget_nodes_refused(drawin_t *d)
{
	bool masks_convert = d->shape_radius >= 0;

	return (d->shape_bounding && !masks_convert
			? WIDGET_REFUSED_SHAPE_BOUNDING : 0)
		| (d->shape_clip && !masks_convert ? WIDGET_REFUSED_SHAPE_CLIP : 0)
		| (d->shape_input ? WIDGET_REFUSED_SHAPE_INPUT : 0)
		| (d->opacity >= 0 && d->opacity < 1
			? WIDGET_REFUSED_OPACITY : 0);
}

/* Drop whatever was stored and say why, which is Lua's signal to paint the
 * whole drawable itself. The reason is the tree dump's to report; nothing
 * here branches on it. */
static bool
nodes_drop(drawin_t *d, enum widget_nodes_state why)
{
	widget_nodes_clear(d);
	d->widget_nodes_state = why;
	return false;
}

void
widget_nodes_gate(lua_State *L, drawin_t *d, int udx)
{
	bool refused = widget_nodes_refused(d) != 0;

	if (refused == d->widget_nodes_refused)
		return;
	d->widget_nodes_refused = refused;
	if (refused)
		nodes_drop(d, WIDGET_NODES_REFUSED);
	/* The drawable is an item of the drawin's own env table, so reaching it
	 * needs the drawin already on the stack. The object registry does not
	 * hold a wibox's drawin, so looking it up there answers nil. */
	if (d->drawable) {
		luaA_object_push_item(L, udx, d->drawable);
		luaA_object_emit_signal(L, -1, "property::surface", 0);
		lua_pop(L, 1);
	}
}

/* Whether len more nodes would take this drawin's output past the budget
 * every converted tree on it shares (widget.h). The drawin's own stored tree
 * is the one being replaced, so it does not count against the new one, and a
 * drawin with no screen declares nowhere and is not counted at all.
 *
 * A hidden drawin's tree is counted, though it declares nothing: visibility
 * flips without a redraw, so a tree admitted while its drawin was hidden
 * would reach Clay unchecked. Counting it can refuse a tree the output had
 * room for, which costs one drawable its conversion; not counting it can
 * exhaust the context, which aborts. */
static bool
over_budget(drawin_t *d, size_t len)
{
	Monitor *m = d->screen ? d->screen->monitor : NULL;
	size_t total = len;

	if (!m)
		return false;
	foreach(item, globalconf.drawins) {
		drawin_t *other = *item;

		if (other != d && other->screen
				&& other->screen->monitor == m)
			total += other->widget_nodes_len;
	}
	return total > WIDGET_NODES_OUTPUT_MAX;
}

bool
widget_nodes_set(lua_State *L, drawin_t *d, int idx)
{
	/* One scratch tree for every drawin: a redraw reads into it and
	 * usually finds the stored tree unchanged. */
	static struct widget_node nodes[WIDGET_NODES_MAX];
	size_t len = 0, leaves = 0;
	unsigned clips = 0;

	text_len = 0;
	d->widget_nodes_refused = widget_nodes_refused(d) != 0;
	if (d->widget_nodes_refused)
		return nodes_drop(d, WIDGET_NODES_REFUSED);
	if (!lua_istable(L, idx))
		return nodes_drop(d, WIDGET_NODES_NONE);
	/* read_tree refuses a tree of its own cap's size before reading a node
	 * of it, so a full scratch tree and a tree past the clip scopes are
	 * the two failures that are a size and not a malformed table. */
	if (!read_tree(L, idx, nodes, &len, &leaves, 0, &clips))
		return nodes_drop(d, len == WIDGET_NODES_MAX
			|| clips > WIDGET_CLIPS_MAX
			? WIDGET_NODES_OVER_BUDGET : WIDGET_NODES_MALFORMED);
	if (over_budget(d, len))
		return nodes_drop(d, WIDGET_NODES_OVER_BUDGET);
	leaves_count(d, leaves);

	d->widget_nodes_state = WIDGET_NODES_CONVERTED;
	if (d->widget_nodes_len == len
			&& memcmp(d->widget_nodes, nodes, len * sizeof(*nodes)) == 0
			&& d->widget_text_len == text_len
			&& (text_len == 0
				|| memcmp(d->widget_text, text_buf, text_len) == 0))
		return true;

	p_delete(&d->widget_nodes);
	d->widget_nodes = p_new(struct widget_node, len);
	memcpy(d->widget_nodes, nodes, len * sizeof(*nodes));
	d->widget_nodes_len = len;
	p_delete(&d->widget_text);
	d->widget_text = text_len ? p_dup(text_buf, text_len) : NULL;
	d->widget_text_len = text_len;
	d->widget_nodes_declared = false;
	/* A container's color or margin can change with no pixel in any leaf
	 * changing, so the tree has to wake the frame path on its own;
	 * drawable:refresh() only speaks for the pixels. */
	drawin_mark_dirty(d);
	return true;
}

cairo_surface_t *
widget_leaf_surface(drawin_t *d, size_t i, bool *fresh)
{
	if (i >= d->widget_leaves_len)
		return NULL;
	*fresh = d->widget_leaves[i].fresh;
	d->widget_leaves[i].fresh = false;
	return cairo_surface_reference(d->widget_leaves[i].native);
}

void
widget_leaves_drawn(lua_State *L, drawin_t *d, int idx)
{
	bool any = false;

	for (size_t i = 0; i < d->widget_leaves_len; i++) {
		lua_rawgeti(L, idx, (int)i + 1);
		if (lua_toboolean(L, -1)) {
			cairo_surface_flush(d->widget_leaves[i].native);
			d->widget_leaves[i].gen++;
			any = true;
		}
		lua_pop(L, 1);
	}
	if (any)
		drawin_mark_dirty(d);
}
