/*
 * declare.c - the per-output declare/solve boundary for the Clay tree
 *
 * Each output owns a Clay context sized to its effective resolution and a
 * render_state parented into a band directly below LyrBlock, so everything
 * the tree will declare stays under the session lock, its covers, and the
 * drag icon. Per dirty frame the declare pass rebuilds the output's tree:
 * every box somewm computes elsewhere enters as a fixed floating leaf
 * attached to Clay's root, so Clay places without solving it.
 *
 * Draw order is Clay's own: zIndex picks the band and declaration order
 * breaks ties inside it. The bands are the table below; within one, clients
 * follow the stack and layer-shell surfaces the oldest first.
 */

#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>

#include "clay.h"
#include "clay_impl.h"
#include "declare.h"
#include "objects/drawable.h"
#include "render.h"
#include "render_text.h"
#include "somewm.h"
#include "somewm_types.h"
#include "globalconf.h"
#include "client.h"
#include "focus.h"
#include "somewm_api.h"
#include "monitor.h"
#include "stack.h"
#include "widget.h"
#include "window.h"
#include "common/buffer.h"
#include "common/lualib.h"
#include "luaa.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/screen.h"

/* One Clay context plus the render_state its solved commands reconcile
 * into. Every output has a desktop band; the lua-lock band is created when
 * the lock engages (covers and the lock surface drawin reconcile into
 * LyrBlock, above locked_bg, below the raised external lock surface). */
struct declare_band {
	Clay_Context *clay;
	void *arena;
	struct wlr_scene_tree *tree;
	struct render_state *render;
	/* The last frame's readback for the tree dump: what the solve
	 * produced, what the reconcile changed, and how long each step took.
	 * Written by declare_output_frame only, so a band that has not drawn
	 * since the last dump reports the frame it did draw. */
	int commands, mutations;
	int64_t declare_us, solve_us, reconcile_us;
};

struct declare_output {
	struct wlr_output *wlr_output;
	struct declare_band desktop;
	struct declare_band lock;
	bool dirty;
	/* This output's crop of the wallpaper (globalconf.wallpaper), and the
	 * surface generation and layout position it was cut from. */
	struct image_entry wallpaper;
	uint64_t wallpaper_gen;
	int wallpaper_x, wallpaper_y;
};

/* Zero hooks until window.c installs the real ones at startup; the
 * reconciler only consults them for CUSTOM commands and borrowed nodes,
 * neither of which can exist before then. */
static struct render_client_hooks client_hooks;

static bool in_frame;

bool
declare_in_frame(void)
{
	return in_frame;
}

static size_t
shape_ops(void *data, const struct render_shape *shape, float w, float h,
	float *ops, size_t cap)
{
	lua_State *L = globalconf.L;
	int ref = ((const struct widget_shape *)shape)->ref;
	lua_pushnumber(L, w);
	lua_pushnumber(L, h);
	lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
	if (!luaA_dofunction(L, 2, 1))
		return 0;
	size_t len = lua_istable(L, -1) ? luaA_rawlen(L, -1) : 0;
	for (size_t i = 0; i < len; i++) {
		lua_rawgeti(L, -1, i + 1);
		bool number = lua_type(L, -1) == LUA_TNUMBER;
		if (number && i < cap)
			ops[i] = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);
		if (!number) {
			len = 0;
			break;
		}
	}
	lua_pop(L, 1);
	return len;
}

void
declare_set_client_hooks(const struct render_client_hooks *hooks)
{
	client_hooks = *hooks;
	client_hooks.shape_ops = shape_ops;
}

/* --- the handle registry --- */

struct handle_entry {
	void *object;
	enum declare_kind kind;
	uint32_t id;
};

static struct handle_entry *handles;
static size_t handles_len, handles_cap;
static uint32_t handle_next = 1;

static uint64_t
handle_pack(enum declare_kind kind, uint32_t id)
{
	return ((uint64_t)kind << 32) | id;
}

/* Chrome scale is tens of objects; linear scans are fine. */
uint64_t
declare_handle_for(void *object, enum declare_kind kind)
{
	for (size_t i = 0; i < handles_len; i++)
		if (handles[i].object == object)
			return handle_pack(handles[i].kind, handles[i].id);
	if (handles_len == handles_cap) {
		handles_cap = handles_cap ? handles_cap * 2 : 32;
		p_realloc(&handles, handles_cap);
	}
	handles[handles_len++] = (struct handle_entry) {
		.object = object, .kind = kind, .id = handle_next++,
	};
	return handle_pack(kind, handles[handles_len - 1].id);
}

void *
declare_handle_get(uint64_t handle, enum declare_kind *kind)
{
	uint32_t id = (uint32_t)handle;

	for (size_t i = 0; i < handles_len; i++) {
		if (handles[i].id != id)
			continue;
		if (handles[i].kind != (enum declare_kind)(handle >> 32))
			return NULL;
		if (kind)
			*kind = handles[i].kind;
		return handles[i].object;
	}
	return NULL;
}

void
declare_handle_drop(void *object)
{
	for (size_t i = 0; i < handles_len; i++) {
		if (handles[i].object == object) {
			handles[i] = handles[--handles_len];
			return;
		}
	}
}

/* --- leaf declarations --- */

static void
declare_leaf(Clay_ElementDeclaration *decl)
{
	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(decl);
	Clay__CloseElement();
}

/* --- the draw order ---
 *
 * One band per line, bottom first. Clay sorts floating tree roots by zIndex
 * (every floating element is one, clay.h:2102-2107; the sort is at
 * clay.h:2603-2615 and is stable), so declaration order decides only within
 * a band. A window's band comes from its stacking attribute; a transient
 * that sets none inherits its parent's. */
enum {
	Z_WALLPAPER = 0,
	Z_LAYER_BACKGROUND = 10,
	Z_CLIENT_DESKTOP = 20,
	Z_DRAWIN_BG = 30,
	Z_LAYER_BOTTOM = 40,
	Z_CLIENT_BELOW = 50,
	Z_CLIENT_NORMAL = 60,
	Z_DRAWIN_WIBOX = 70,
	Z_LAYER_TOP = 80,
	Z_CLIENT_ABOVE = 90,
	Z_DRAWIN_TOP = 100,
	Z_FULLSCREEN_BG = 105,
	Z_CLIENT_FULLSCREEN = 110,
	Z_LAYER_OVERLAY = 120,
	Z_CLIENT_ONTOP = 130,
	Z_DRAWIN_OVERLAY = 140,
	/* Override-redirect X11 windows (menus, tooltips, drag icons) carry
	 * no stacking attribute to place them and are always transient UI for
	 * the window below, so they sit above everything. */
	Z_CLIENT_UNMANAGED = 150,
};

/* The lock band is a separate Clay context with its own order. */
enum {
	Z_LOCK_COVER = 10,
	Z_LOCK_SURFACE = 20,
};

/* The placement every box somewm computes elsewhere enters with: a fixed
 * size at an explicit offset from the root, so Clay places it without
 * solving for it. */
static void
place_fixed(Clay_ElementDeclaration *decl, int16_t z, int x, int y,
	int w, int h)
{
	decl->layout.sizing.width = CLAY_SIZING_FIXED(w);
	decl->layout.sizing.height = CLAY_SIZING_FIXED(h);
	decl->floating.offset = (Clay_Vector2) { x, y };
	decl->floating.attachTo = CLAY_ATTACH_TO_ROOT;
	decl->floating.zIndex = z;
	/* Clay's pointer query walks the roots topmost first and stops at
	 * the first floating one it hits unless it passes the pointer
	 * through (clay.h:3913, Clay_SetPointerState); every root here does,
	 * so a query under a drawin reaches the drawin's own tree whatever
	 * lies above it. What takes input is the scene's to decide. */
	decl->floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
}

static Clay_ElementDeclaration
leaf_at(Clay_String label, uint32_t index, int16_t z,
	int x, int y, int w, int h)
{
	Clay_ElementDeclaration decl = {
		.id = Clay__HashString(label, index, 0),
	};

	place_fixed(&decl, z, x, y, w, h);
	return decl;
}

/* The per-element userData word (render.h): registry id in bits 0-31, kind
 * in 32-39, opacity byte in 40-47. A packed integer rather than a pointer,
 * so a retained command can never dangle into freed registry state; the low
 * 40 bits are exactly a declare handle. */
_Static_assert(sizeof(void *) >= 8, "userData packing needs 64-bit pointers");

static void *
leaf_userdata(uint64_t handle, float opacity)
{
	return (void *)(uintptr_t)(handle
		| ((uint64_t)(1 + (unsigned)(opacity * 254.0f + 0.5f))
			<< RENDER_UD_OPACITY_SHIFT));
}

/* The word with its two clip bytes (render.h): the scope a rectangle opens
 * and the scope the command is clipped by. */
static void *
userdata_clip(void *word, unsigned opens, unsigned clipped_by)
{
	return (void *)((uintptr_t)word
		| (uint64_t)opens << RENDER_UD_OPENS_SHIFT
		| (uint64_t)clipped_by << RENDER_UD_CLIP_SHIFT);
}

/* The band that drew a node is the one whose render_state retains it, which
 * is not the band under the pointer: a drawin overhanging an output edge and
 * a floating client dragged clear of its monitor both draw on a neighbor
 * while the band that declared them stays where it is. Every band answers,
 * and a node belongs to at most one, so the first hit is the owner. Asking
 * all of them also covers a point in a gap between misaligned outputs, where
 * there is no monitor to ask. */
void *
declare_hit(struct wlr_scene_node *node, enum declare_kind *kind)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		struct declare_output *dout = m->declare;
		void *ud;

		if (!dout)
			continue;
		ud = render_hit_userdata(dout->desktop.render, node);
		if (!ud && dout->lock.render)
			ud = render_hit_userdata(dout->lock.render, node);
		if (ud)
			return declare_handle_get(
				declare_userdata_handle(ud), kind);
	}
	return NULL;
}

/* somewm colors are straight-alpha 0-1 floats; Clay_Color is 0-255.
 * The renderer premultiplies once when converting back for wlr_scene. */
static Clay_Color
clay_color(const float rgba[4])
{
	return (Clay_Color) {
		rgba[0] * 255.0f, rgba[1] * 255.0f,
		rgba[2] * 255.0f, rgba[3] * 255.0f,
	};
}

static void
declare_shadow(struct shadow_leaves *s, const shadow_config_t *config,
	Clay_String label, uint32_t id, int16_t z, int x, int y, int w, int h)
{
	struct wlr_box boxes[SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT];

	shadow_leaves_update(s, config);
	if (!s->ready || !shadow_layout(config, w, h, boxes))
		return;
	float rgba[4] = { config->color[0], config->color[1],
		config->color[2], shadow_paint(config) };
	/* The index participates in the hash (third_party/clay.h:1376).
	 * Sixteen slots per object keep its eleven parts distinct. */
	for (int i = 0; i < SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT; i++) {
		struct wlr_box b = boxes[i];

		if (b.width <= 0 || b.height <= 0)
			continue;
		Clay_ElementDeclaration leaf = leaf_at(label, id * 16 + i, z,
			x + b.x, y + b.y, b.width, b.height);
		if (i < SHADOW_SLICE_COUNT) {
			if (!s->tex[i].native)
				continue;
			leaf.image.imageData = &s->tex[i];
		} else {
			leaf.backgroundColor = clay_color(rgba);
		}
		declare_leaf(&leaf);
	}
}

static void declare_widget_tree(const struct widget_host *host, int16_t z,
	void *userdata);

static void
declare_titlebar(Client *c, client_titlebar_t bar, uint32_t id, int16_t z)
{
	struct widget_host host;
	int size = c->titlebar[bar].size;

	if (size == 0 || !client_titlebar_host(c, c->titlebar[bar].drawable, &host))
		return;
	bool horizontal = bar == CLIENT_TITLEBAR_TOP || bar == CLIENT_TITLEBAR_BOTTOM;
	uint64_t handle = declare_handle_for(c->titlebar[bar].drawable, DECLARE_KIND_TITLEBAR);
	Clay_ElementDeclaration e = {
		.id = Clay__HashString(CLAY_STRING("client.titlebar"), id * 4 + bar, 0),
		.layout.sizing = {
			horizontal ? CLAY_SIZING_GROW(0) : CLAY_SIZING_FIXED(size),
			horizontal ? CLAY_SIZING_FIXED(size) : CLAY_SIZING_GROW(0),
		},
	};

	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(&e);
	if (host.tree->nodes_len > 0)
		declare_widget_tree(&host, z, leaf_userdata(handle, 1.0f));
	else if (c->titlebar[bar].content.native) {
		Clay_ElementDeclaration content = {
			.id = Clay__HashString(CLAY_STRING("titlebar.image"), host.id, 0),
			.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
			.image.imageData = &c->titlebar[bar].content,
			.userData = leaf_userdata(handle, 1.0f),
		};
		declare_leaf(&content);
	}
	Clay__CloseElement();
}

/* Padding starts the children inside the border (third_party/clay.h:2704).
 * Fixed bars leave the growing surface the remaining space
 * (third_party/clay.h:2349-2392, 2409-2411). */
static void
declare_client(Client *c, Monitor *m, int16_t z)
{
	uint64_t handle = declare_handle_for(c, DECLARE_KIND_CLIENT);
	uint32_t id = (uint32_t)handle;
	int bw = c->fullscreen ? 0 : c->bw;
	int fw = c->geometry.width + 2 * bw;
	int fh = c->geometry.height + 2 * bw;
	int x = c->geometry.x - m->m.x;
	int y = c->geometry.y - m->m.y;
	bool clamp = client_clamps_to_monitor(c);

	if (clamp && (x + bw + c->geometry.width <= 0
			|| y + bw + c->geometry.height <= 0
			|| x + bw >= m->m.width
			|| y + bw >= m->m.height))
		return;

	declare_shadow(&c->shadow,
		shadow_get_effective_config(c->shadow_config, false),
		CLAY_STRING("client.shadow"), id, z, x, y, fw, fh);
	Clay_ElementDeclaration frame = leaf_at(
		CLAY_STRING("client"), id, z, x, y, fw, fh);
	frame.layout.layoutDirection = CLAY_TOP_TO_BOTTOM;
	frame.layout.padding = (Clay_Padding) { bw, bw, bw, bw };
	frame.userData = leaf_userdata(handle, 1.0f);
	if (clamp)
		frame.userData = userdata_clip(frame.userData, 0, RENDER_CLIP_BOUNDS);
	if (bw > 0) {
		float rgba[4];

		client_border_rgba(c, rgba);
		frame.border.color = clay_color(rgba);
		frame.border.width = (Clay_BorderWidth) { bw, bw, bw, bw, 0 };
	}
	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(&frame);
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_TOP, id, z);
	Clay_ElementDeclaration row = {
		.id = Clay__HashString(CLAY_STRING("client.row"), id, 0),
		.layout = {
			.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
			.layoutDirection = CLAY_LEFT_TO_RIGHT,
		},
	};
	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(&row);
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_LEFT, id, z);
	Clay_ElementDeclaration surface = {
		.id = Clay__HashString(CLAY_STRING("client.surface"), id, 0),
		.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
		.custom.customData = (void *)(uintptr_t)handle,
		.userData = leaf_userdata(handle, 1.0f),
	};
	declare_leaf(&surface);
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_RIGHT, id, z);
	Clay__CloseElement();
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_BOTTOM, id, z);
	Clay__CloseElement();
}

static bool
declarable_client(Client *c)
{
	if (!c || !c->scene || !client_surface(c)
			|| !client_surface(c)->mapped)
		return false;
	/* Banning's visibility fact (tags, minimized) becomes a declare
	 * filter: an undeclared client's tree is released disabled by the
	 * sweep. Unmanaged clients are not tag-tracked. */
	return client_is_unmanaged(c) || client_isvisible(c);
}

/* A transient that sets no stacking attribute of its own inherits its
 * parent's band and is declared right above it. One that sets ontop, above,
 * below or fullscreen declares as a root in that band instead, so the
 * attribute wins over the parent's placement, as in AwesomeWM.
 * stack_client_layer() returns WINDOW_LAYER_IGNORE for exactly the first
 * case, so this implies c->transient_for. */
static bool
transient_inherits(Client *c)
{
	return stack_client_layer(c) == WINDOW_LAYER_IGNORE;
}

static int16_t
client_z(Client *c)
{
	if (client_is_unmanaged(c))
		return Z_CLIENT_UNMANAGED;

	switch (stack_client_effective_layer(c)) {
	case WINDOW_LAYER_DESKTOP:
		return Z_CLIENT_DESKTOP;
	case WINDOW_LAYER_BELOW:
		return Z_CLIENT_BELOW;
	case WINDOW_LAYER_ABOVE:
		return Z_CLIENT_ABOVE;
	case WINDOW_LAYER_FULLSCREEN:
		return Z_CLIENT_FULLSCREEN;
	case WINDOW_LAYER_ONTOP:
		return Z_CLIENT_ONTOP;
	default:
		return Z_CLIENT_NORMAL;
	}
}

/* Inheriting transients ride their parent: declared right above it in the
 * band it resolved to, mirroring stack_transients_above() (stack.c).
 * Unmanaged children are excluded; declare_unmanaged_clients() owns every
 * unmanaged client, and declaring one here too would hash a duplicate Clay
 * id and abort. */
static void
declare_client_tree(Client *c, Monitor *m)
{
	declare_client(c, m, client_z(c));
	foreach(node, globalconf.stack)
		if ((*node)->transient_for == c && (*node)->mon == m
				&& !client_is_unmanaged(*node)
				&& transient_inherits(*node)
				&& declarable_client(*node))
			declare_client_tree(*node, m);
}

/* Whether declare_client_tree() will reach c through its parent. When it
 * will not (c carries a stacking attribute of its own, or the parent is
 * minimized, unmapped, unmanaged, or on another output), c declares as a
 * root instead of vanishing; the old scene path kept exactly these clients
 * visible per-client. The immediate parent suffices: every managed
 * declarable client on m is declared, as a root or by riding one, so a
 * declarable parent is a declared parent. */
static bool
transient_rides_parent(Client *c, Monitor *m)
{
	Client *p = c->transient_for;

	return p && transient_inherits(c) && p->mon == m
		&& !client_is_unmanaged(p) && declarable_client(p);
}

static void
declare_clients(Monitor *m)
{
	foreach(node, globalconf.stack) {
		Client *c = *node;

		/* Cheap pointer filters first, then the riding test, which
		 * skips a transient before it pays for its own tag-visibility
		 * check. Unmanaged (override-redirect) clients are declared by
		 * declare_unmanaged_clients() instead. */
		if (!c || c->mon != m || client_is_unmanaged(c))
			continue;
		if (transient_rides_parent(c, m))
			continue;
		if (!declarable_client(c))
			continue;
		declare_client_tree(c, m);
	}
}

/* Unmanaged clients have no c->mon assignment to trust; each declares on
 * exactly one output, the one under its center, so two outputs never fight
 * over borrowing the same scene tree. */
static Monitor *
monitor_for_unmanaged(Client *c)
{
	Monitor *m = xytomon(c->geometry.x + c->geometry.width / 2.0,
		c->geometry.y + c->geometry.height / 2.0);

	return m ? m : c->mon;
}

static void
declare_unmanaged_clients(Monitor *m)
{
	foreach(node, globalconf.stack) {
		Client *c = *node;

		if (!c || !client_is_unmanaged(c))
			continue;
		if (monitor_for_unmanaged(c) != m)
			continue;
		if (!declarable_client(c))
			continue;
		declare_client(c, m, client_z(c));
	}
}

static void
declare_layer_surface(LayerSurface *l, Monitor *m, int16_t z)
{
	uint64_t handle = declare_handle_for(l, DECLARE_KIND_LAYER);
	struct wlr_layer_surface_v1 *ls = l->layer_surface;
	/* l->geom is output-local, captured by arrangelayer() from the
	 * layer-shell solve; the scene node's own position belongs to the
	 * reconciler and may hold this same value already. */
	Clay_ElementDeclaration s = leaf_at(CLAY_STRING("layer.surface"),
		(uint32_t)handle, z, l->geom.x, l->geom.y,
		ls->current.actual_width, ls->current.actual_height);

	s.custom.customData = (void *)(uintptr_t)handle;
	s.userData = leaf_userdata(handle, 1.0f);
	declare_leaf(&s);
}

static void
declare_layer_surfaces(Monitor *m)
{
	static const int16_t band_z[] = {
		[ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND] = Z_LAYER_BACKGROUND,
		[ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM] = Z_LAYER_BOTTOM,
		[ZWLR_LAYER_SHELL_V1_LAYER_TOP] = Z_LAYER_TOP,
		[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY] = Z_LAYER_OVERLAY,
	};
	LayerSurface *l;

	/* protocols.c prepends new surfaces to m->layers, and scene child
	 * order stacks newer surfaces on top; reverse iteration declares the
	 * oldest first, at the bottom. */
	for (size_t band = 0; band < LENGTH(m->layers); band++) {
		wl_list_for_each_reverse(l, &m->layers[band], link) {
			if (!l->mapped || !l->scene)
				continue;
			declare_layer_surface(l, m, band_z[band]);
		}
	}
}

/* --- the converted widget tree (widget.h) ---
 *
 * One element per node, nested as lua/wibox/clay.lua compiled them. The
 * root is the drawin's own box, fixed and floating like any other leaf here.
 * Clipping is the renderer's, not Clay's: a Clay clip element is a scroll
 * container, a context holds ten (clay.h:2194), and one clipping axis stops
 * Clay compressing the children along it (clay.h:2305-2311). Instead every
 * node's word names the scope it is clipped by and, for the root and a
 * rounded container, the scope it opens (widget.c numbers them, render.h
 * says how the renderer reads them), so a layout that overflows draws
 * nothing outside the drawin and a rounded background cuts its children to
 * its arc, as the container's own clip did.
 *
 * Ids follow the path from the root: the root hashes the drawin's registry
 * id, and a child hashes its index seeded with its parent's id, the shape of
 * CLAY_IDI_LOCAL (clay.h:92). A widget inserted among its siblings renames
 * the siblings after it and their subtrees and nothing else, so the rest of
 * the tree keeps its retained nodes; a preorder index would rename every
 * node after the insertion point.
 *
 * Every node carries the drawin's handle in userData, containers included:
 * the pointer over a gap between leaves lands on a container's rectangle,
 * and declare_hit has to resolve that node to the drawin (input.c then takes
 * drawin-local coordinates from the drawin's own box, not the node's).
 */
static Clay_ElementId
widget_root_id(uint32_t id)
{
	return Clay__HashString(CLAY_STRING("drawin.widget"), id, 0);
}

/* Clay's own hash of a child index under a parent id (Clay__HashNumber,
 * clay.h, which the header keeps to itself), verbatim: a text element gets
 * exactly this id from Clay__OpenTextElement, and reading its box back
 * means computing the same one. */
static uint32_t
clay_hash_number(uint32_t offset, uint32_t seed)
{
	uint32_t hash = seed;

	hash += (offset + 48);
	hash += (hash << 10);
	hash ^= (hash >> 6);
	hash += (hash << 3);
	hash ^= (hash >> 11);
	hash += (hash << 15);
	return hash + 1;
}

/* Child k's id. A text element's id is Clay's own, hashed from its index
 * among the parent's children (Clay__OpenTextElement), which is k. */
static Clay_ElementId
widget_child_id(struct widget_tree *d, size_t child, Clay_ElementId parent,
	uint16_t index)
{
	if (d->nodes[child].text)
		return (Clay_ElementId) { .id = clay_hash_number(index, parent.id) };
	return Clay__HashString(CLAY_STRING("drawin.widget"), index, parent.id);
}

static Clay_SizingAxis
widget_sizing(const struct widget_node *n, int axis)
{
	switch (n->sizing[axis]) {
	case WIDGET_SIZING_FIXED:
		return CLAY_SIZING_FIXED(n->size[axis]);
	case WIDGET_SIZING_PERCENT:
		/* Percent has no min/max clamps (third_party/clay.h:1863-1871). */
		return CLAY_SIZING_PERCENT(n->size[axis]);
	case WIDGET_SIZING_GROW:
		return CLAY_SIZING_GROW(n->min[axis], n->max[axis]);
	default:
		return CLAY_SIZING_FIT(n->min[axis], n->max[axis]);
	}
}

static Clay_ElementDeclaration
widget_node_decl(const struct widget_node *n, Clay_ElementId id, int16_t z,
	void *userdata)
{
	Clay_ElementDeclaration e = {
		.id = id,
		.layout = {
			.sizing = { widget_sizing(n, 0), widget_sizing(n, 1) },
			.padding = { n->pad[0], n->pad[1], n->pad[2], n->pad[3] },
			.childGap = n->gap,
			.childAlignment = { n->align[0], n->align[1] },
			.layoutDirection = n->vertical
				? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT,
		},
		.cornerRadius = { n->radius, n->radius, n->radius, n->radius },
		.userData = userdata,
	};

	if (!n->shape && n->bg[3] > 0)
		e.backgroundColor = clay_color(n->bg);
	else if (n->clip_opens)
		/* A transparent root, or a rounded container with no fill, still
		 * clips what it holds: Clay draws a RECTANGLE only for a fill, so
		 * the scope rides a CUSTOM command the renderer realizes as an
		 * input-only rect (render.h). */
		e.custom.customData = RENDER_CLIP_MARK;
	if (n->border[3] > 0) {
		e.border.color = clay_color(n->border);
		e.border.width = (Clay_BorderWidth) {
			n->bw[0], n->bw[1], n->bw[2], n->bw[3], 0 };
	}
	if (n->scroll) {
		e.clip = (Clay_ClipElementConfig) {
			.horizontal = n->scroll == 1,
			.vertical = n->scroll == 2,
			.childOffset = { n->scroll == 1 ? -n->scrolled : 0,
				n->scroll == 2 ? -n->scrolled : 0 },
		};
	}
	if (n->floating) {
		/* A stack child: off the flow, at the parent's top left, in the
		 * drawin's band (a floating element is its own tree root, sorted
		 * by zIndex and then declaration order, clay.h:2603-2615). */
		e.floating.offset = (Clay_Vector2) { n->offset[0], n->offset[1] };
		e.floating.attachTo = CLAY_ATTACH_TO_PARENT;
		e.floating.zIndex = z;
		/* A stack child lies over its siblings and passes the pointer
		 * through to them, as every widget under the point is under it
		 * (place_fixed says the same of the roots). */
		e.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
	}
	return e;
}

static size_t
declare_widget_subtree(const struct widget_host *host, size_t i, Clay_ElementId id, int16_t z,
	void *userdata, size_t *leaf)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	void *word = userdata_clip(userdata, n->clip_opens, n->clip_by);
	Clay_ElementDeclaration e;
	size_t next = i + 1;

	/* A text element, as CLAY_TEXT declares one: the run and its config,
	 * no children, the drawin's word riding the config's userData to the
	 * renderer with the ellipsize flag in it (render_text.h), so the run
	 * clips like its siblings and a pointer over the glyphs is the
	 * drawin's. */
	if (n->text) {
		Clay_TextElementConfig cfg = {
			.userData = (void *)((uintptr_t)word
				| (n->ellipsize ? RENDER_TEXT_ELLIPSIZE : 0)),
			.textColor = clay_color(n->fg),
			.fontId = n->font,
			.wrapMode = n->wrap,
			.textAlignment = n->text_align,
		};
		Clay__OpenTextElement((Clay_String) {
			.length = (int32_t)n->text_len,
			.chars = d->text + n->text_off,
		}, Clay__StoreTextElementConfig(cfg));
		return next;
	}

	e = widget_node_decl(n, id, z, word);
	if (i == 0) {
		/* A titlebar root attaches at its parent's origin; a drawin
		 * uses an output-local offset (third_party/clay.h:2074-2080,
		 * 2625-2677). Fixed axes use the host box, while an awful.popup
		 * fits within its tree's limits. */
		e.floating.offset = host->in_parent ? (Clay_Vector2) { 0, 0 }
			: (Clay_Vector2) { host->x, host->y };
		e.floating.attachTo = host->in_parent
			? CLAY_ATTACH_TO_PARENT : CLAY_ATTACH_TO_ROOT;
		e.floating.zIndex = z;
		e.layout.sizing = (Clay_Sizing) {
			n->sizing[0] == WIDGET_SIZING_FIXED
				? CLAY_SIZING_FIXED(host->w) : widget_sizing(n, 0),
			n->sizing[1] == WIDGET_SIZING_FIXED
				? CLAY_SIZING_FIXED(host->h) : widget_sizing(n, 1),
		};
		/* A shaped drawin's masks, as the root's corners (drawin.h
		 * shape_radius), which the root's clip scope carries to every
		 * node under it. */
		if (host->radius > 0)
			e.cornerRadius = (Clay_CornerRadius) { host->radius,
				host->radius, host->radius, host->radius };
	}
	if (n->raster && *leaf < d->leaves_len)
		e.image.imageData = &d->leaves[(*leaf)++];
	if (n->shape)
		e.custom.customData = render_shape_tag(&d->shapes[n->shape - 1].shape);

	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(&e);
	for (uint16_t k = 0; k < n->children; k++)
		next = declare_widget_subtree(host, next,
			widget_child_id(d, next, id, k), z, userdata, leaf);
	Clay__CloseElement();
	return next;
}

static void
declare_widget_tree(const struct widget_host *host, int16_t z,
	void *userdata)
{
	struct widget_tree *d = host->tree;
	size_t leaf = 0;

	d->declared = true;
	declare_widget_subtree(host, 0, widget_root_id(host->id), z, userdata,
		&leaf);
}

/* --- drawins ---
 *
 * Shadow leaves below border below content. The drawin owns their image
 * entries; gen bumps on content change.
 * Opacity applies to the content leaf only, matching the old scene-buffer
 * path, which never set opacity on the border or shadow. */
static void
declare_drawin(drawin_t *d, Monitor *m, int16_t z)
{
	uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
	uint32_t id = (uint32_t)handle;
	int bw = d->border_width;
	int x = d->x - m->m.x;
	int y = d->y - m->m.y;
	float opacity = d->opacity >= 0 ? (float)d->opacity : 1.0f;

	declare_shadow(&d->shadow,
		shadow_get_effective_config(d->shadow_config, true),
		CLAY_STRING("drawin.shadow"), id, z, x, y, d->width, d->height);
	if (bw > 0 && d->border_entry.native) {
		/* No userData: the input filter (window.c hook_accepts_input)
		 * reads a bare word as "never accepts input", which is what the
		 * old border_buffer's point_accepts_input answered, and the
		 * shadow leaf below gets the same treatment for free. */
		Clay_ElementDeclaration b = leaf_at(CLAY_STRING("drawin.border"),
			id, z, x - bw, y - bw,
			d->width + 2 * bw, d->height + 2 * bw);
		b.image.imageData = &d->border_entry;
		declare_leaf(&b);
	}

	/* A converted widget tree declares its own leaves, each carrying the
	 * pixels of one subtree lua/wibox/clay.lua could not express, at the
	 * box Clay solves for it. */
	if (d->widgets.nodes_len > 0) {
		struct widget_host host;

		if (drawin_widget_host(d, &host))
			declare_widget_tree(&host, z, leaf_userdata(handle, opacity));
		return;
	}

	Clay_ElementDeclaration c = leaf_at(CLAY_STRING("drawin.image"), id, z,
		x, y, d->width, d->height);
	c.image.imageData = &d->content_entry;
	c.userData = leaf_userdata(handle, opacity);
	declare_leaf(&c);
}

/* Map-then-draw: a drawin only declares once its content entry holds pixels,
 * the same gate the old path applied by enabling the scene node after the
 * first refresh. */
static bool
declarable_drawin(drawin_t *d, Monitor *m)
{
	return d->visible
		&& d->content_entry.native
		&& d->screen && d->screen->monitor == m;
}

/* The drawin band policy (AwesomeWM compat): desktop and splash below
 * clients like wallpaper, ontop above everything, dock above normal
 * windows, everything else in the wibox band. */
static int16_t
drawin_z(drawin_t *d)
{
	if (d->type == WINDOW_TYPE_DESKTOP || d->type == WINDOW_TYPE_SPLASH)
		return Z_DRAWIN_BG;
	if (d->ontop)
		return Z_DRAWIN_OVERLAY;
	if (d->type == WINDOW_TYPE_DOCK)
		return Z_DRAWIN_TOP;
	return Z_DRAWIN_WIBOX;
}

static void
declare_drawins(Monitor *m)
{
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		/* Lock drawins belong to the lock pass while locked. */
		if (session_is_locked() && some_is_lock_drawin(d))
			continue;
		if (!declarable_drawin(d, m))
			continue;
		declare_drawin(d, m, drawin_z(d));
	}
}

/* The opaque backing the xdg protocol requires under a non-opaque
 * fullscreen surface; replaces the per-monitor fullscreen_bg scene rect,
 * enabled under the same condition (arrange()'s focustop check). */
static void
declare_fullscreen_bg(Monitor *m)
{
	Client *c = focustop(m);

	if (!c || !c->fullscreen)
		return;

	Clay_ElementDeclaration bg = leaf_at(CLAY_STRING("fullscreen_bg"), 0,
		Z_FULLSCREEN_BG, 0, 0, m->m.width, m->m.height);
	bg.backgroundColor = clay_color(globalconf.appearance.fullscreen_bg);
	declare_leaf(&bg);
}

/* The wallpaper: this output's crop of the surface root.c paints over the
 * whole layout, an image leaf under everything else. Cut again when the
 * surface changes or the output moves in the layout; the entry's pointer
 * stays, so the leaf's node is retained and re-rastered. The leaf's word
 * names the Monitor under a kind of its own, so the dump can say what it is
 * and the input filter (window.c) refuses it pointer input like a drawin's
 * border. */
static void
declare_wallpaper(Monitor *m)
{
	struct declare_output *dout = m->declare;
	struct image_entry *e = &dout->wallpaper;
	cairo_surface_t *wall = globalconf.wallpaper;
	uint64_t handle;
	Clay_ElementDeclaration w;

	if (!wall || m->m.width <= 0 || m->m.height <= 0) {
		image_entry_set(e, NULL);
		return;
	}
	if (dout->wallpaper_gen != globalconf.wallpaper_gen
			|| e->width != m->m.width || e->height != m->m.height
			|| dout->wallpaper_x != m->m.x || dout->wallpaper_y != m->m.y) {
		cairo_surface_t *crop = cairo_image_surface_create(
			CAIRO_FORMAT_ARGB32, m->m.width, m->m.height);
		cairo_t *cr;

		if (cairo_surface_status(crop) != CAIRO_STATUS_SUCCESS) {
			cairo_surface_destroy(crop);
			image_entry_set(e, NULL);
			return;
		}
		cr = cairo_create(crop);
		cairo_set_source_surface(cr, wall, -m->m.x, -m->m.y);
		cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
		cairo_paint(cr);
		cairo_destroy(cr);
		cairo_surface_flush(crop);
		image_entry_set(e, crop);
		dout->wallpaper_gen = globalconf.wallpaper_gen;
		dout->wallpaper_x = m->m.x;
		dout->wallpaper_y = m->m.y;
	}

	handle = declare_handle_for(m, DECLARE_KIND_WALLPAPER);
	w = leaf_at(CLAY_STRING("wallpaper"), (uint32_t)handle, Z_WALLPAPER,
		0, 0, m->m.width, m->m.height);
	w.image.imageData = e;
	w.userData = leaf_userdata(handle, 1.0f);
	declare_leaf(&w);
}

static void
declare_scene(Monitor *m)
{
	declare_wallpaper(m);
	declare_layer_surfaces(m);
	declare_clients(m);
	declare_drawins(m);
	declare_fullscreen_bg(m);
	declare_unmanaged_clients(m);
	/* Session lock: locked_bg, the lock covers, and the lock surface stay
	 * C-owned scene nodes in LyrBlock, above this whole band. */
}

/* The boxes of one subtree, in the preorder the tree table uses, rounded
 * against the root's own box so a box crossing into Lua is the whole
 * drawin-local pixel. Edges round, not the size, so two boxes that share an
 * edge in Clay share it here. With dev, each raster leaf's box in device
 * pixels as well, by the arithmetic rasterize_image (render.c) runs on the
 * same box, so the surface Lua draws into is the size the renderer shows it
 * at and is never resampled. */
static size_t
widget_boxes_walk(struct widget_tree *d, size_t i, Clay_ElementId id, int (*boxes)[4],
	int *n, Clay_BoundingBox root, int (*dev)[2], int *nleaf, float scale)
{
	const struct widget_node *node = &d->nodes[i];
	Clay_ElementData data = Clay_GetElementData(id);
	size_t next = i + 1;

	if (data.found && node->widget) {
		Clay_BoundingBox b = data.boundingBox;
		int x0 = (int)floorf(b.x - root.x + 0.5f);
		int y0 = (int)floorf(b.y - root.y + 0.5f);

		boxes[*n][0] = x0;
		boxes[*n][1] = y0;
		boxes[*n][2] = (int)floorf(b.x + b.width - root.x + 0.5f) - x0;
		boxes[*n][3] = (int)floorf(b.y + b.height - root.y + 0.5f) - y0;
		(*n)++;
	}
	/* A painted leaf's device size; an image leaf brings its own pixels. */
	if (dev && data.found && node->raster && !node->image) {
		Clay_BoundingBox b = data.boundingBox;

		dev[*nleaf][0] = render_device_len((int)b.x, (int)b.width, scale);
		dev[*nleaf][1] = render_device_len((int)b.y, (int)b.height, scale);
		(*nleaf)++;
	}
	for (uint16_t k = 0; k < node->children; k++)
		next = widget_boxes_walk(d, next, widget_child_id(d, next, id, k),
			boxes, n, root, dev, nleaf, scale);
	return next;
}

/* Whether Clay's last pointer query named id. */
static bool
pointer_over(Clay_ElementIdArray ids, Clay_ElementId id)
{
	for (int32_t k = 0; k < ids.length; k++)
		if (ids.internalArray[k].id == id.id)
			return true;
	return false;
}

/* The preorder indices of the widget nodes Clay's pointer query named, in
 * preorder: parents before children, a stack's children bottom to top,
 * which is the order find_widgets has always answered in. */
static size_t
widget_hits_walk(struct widget_tree *d, size_t i, Clay_ElementId id,
	Clay_ElementIdArray ids, int *out, int *n, int cap)
{
	const struct widget_node *node = &d->nodes[i];
	size_t next = i + 1;

	if (node->widget && *n < cap && pointer_over(ids, id))
		out[(*n)++] = (int)i;
	for (uint16_t k = 0; k < node->children; k++)
		next = widget_hits_walk(d, next, widget_child_id(d, next, id, k),
			ids, out, n, cap);
	return next;
}

int
declare_widget_hits(const struct widget_host *host, double x, double y, int *out, int cap)
{
	struct widget_tree *d = host->tree;
	Monitor *m = host->m;
	struct declare_output *dout = m ? m->declare : NULL;
	struct declare_band *band;
	Clay_Context *previous;
	Clay_ElementId root_id;
	Clay_ElementIdArray ids;
	int n = 0;

	if (!dout || !d->declared)
		return 0;
	band = session_is_locked() && some_is_lock_drawin(declare_handle_get(
			handle_pack(DECLARE_KIND_DRAWIN, host->id), NULL))
		? &dout->lock : &dout->desktop;
	if (!band->clay)
		return 0;
	/* The query runs against the boxes of the output's last solve, in
	 * output coordinates, and answers every element under the point
	 * across the whole context: this tree's nodes are picked out of it. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	Clay_SetPointerState((Clay_Vector2) {
		(float)(host->x + x), (float)(host->y + y) }, false);
	ids = Clay_GetPointerOverIds();
	root_id = widget_root_id(host->id);
#ifdef SOMEWM_RENDER_VERIFY
	/* The scene named this drawable at the point (input.c), so the query
	 * (third_party/clay.h:3900-3967) must reach its root: the two disagreeing
	 * is the divergence the tree==scene verifier exists to catch. */
	if (!pointer_over(ids, root_id)) {
		wlr_log(WLR_ERROR, "scene==clay: the scene hit drawable %dx%d+%d+%d "
			"at %g,%g but Clay's query does not reach its root",
			host->w, host->h, host->x + m->m.x, host->y + m->m.y, x, y);
		abort();
	}
#endif
	widget_hits_walk(d, 0, root_id, ids, out, &n, cap);
	Clay_SetCurrentContext(previous);
	return n;
}

int
declare_widget_boxes(const struct widget_host *host, int (*boxes)[4])
{
	struct widget_tree *d = host->tree;
	Monitor *m = host->m;
	struct declare_output *dout = m ? m->declare : NULL;
	Clay_Context *previous;
	Clay_ElementId root_id;
	Clay_ElementData root;
	int n = 0;

	/* Clay's hashmap answers with the last box an id ever had, so a tree
	 * the declare pass has not reached yet would read back the boxes of
	 * the one it replaced. Report nothing until it has. */
	if (!dout || !d->declared)
		return 0;

	/* What the last frame solved, not a second solve of its own: Clay
	 * keeps every element's box in the context's hashmap, so the readback
	 * is one lookup per node against the boxes the output drew. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(dout->desktop.clay);
	root_id = widget_root_id(host->id);
	root = Clay_GetElementData(root_id);
	if (root.found)
		widget_boxes_walk(d, 0, root_id, boxes, &n, root.boundingBox,
			NULL, NULL, 1);
	Clay_SetCurrentContext(previous);
	return n;
}

static void handle_clay_error(Clay_ErrorData error);

/* Solve d's tree now, before any frame, and read every box back: what
 * drawable:_clay_nodes returns to Lua, which sizes the leaf surfaces and
 * draws and hit-tests against them. The solve runs in a context of its own
 * holding only this tree: a partial layout in the output's context would
 * evict every other element's box from Clay's hashmap (clay.h, generation
 * eviction in Clay__AddHashMapItem), and the frame's own declare, solve and
 * reconcile follow anyway. The tree is placed where the frame will place it,
 * at the drawin's output-local origin, so the device rounding matches the
 * renderer's to the pixel. */
int
declare_widget_solve(const struct widget_host *host, int (*boxes)[4], int (*dev)[2])
{
	struct widget_tree *d = host->tree;
	static Clay_Context *ctx;
	Monitor *m = host->m;
	Clay_Context *previous;
	Clay_ElementId root_id;
	Clay_ElementData root;
	int n = 0, nleaf = 0;
	size_t leaf = 0;

	if (!m || d->nodes_len == 0)
		return 0;
	in_frame = true;
	if (!ctx) {
		uint32_t arena_size = Clay_MinMemorySize();

		ctx = Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(
			arena_size, malloc(arena_size)),
			(Clay_Dimensions) { 0, 0 },
			(Clay_ErrorHandler) {
				.errorHandlerFunction = handle_clay_error });
		Clay_SetCullingEnabled(false);
		Clay_SetMeasureTextFunction(render_measure_text, NULL);
	}
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(ctx);
	render_text_set_measure_scale(m->wlr_output->scale);
	clay_scroll_records_clear();
	Clay_BeginLayout();
	root_id = widget_root_id(host->id);
	struct widget_host isolated = *host;
	isolated.in_parent = false;
	declare_widget_subtree(&isolated, 0, root_id, 0, NULL, &leaf);
	Clay_EndLayout();
	root = Clay_GetElementData(root_id);
	if (root.found)
		widget_boxes_walk(d, 0, root_id, boxes, &n, root.boundingBox,
			dev, &nleaf, m->wlr_output->scale);
	Clay_SetCurrentContext(previous);
	in_frame = false;
	return n;
}

int
declare_output_order(struct declare_output *dout, Monitor *m, void **objects,
	int cap)
{
	int n = 0;

	Clay_SetCurrentContext(dout->desktop.clay);
	render_text_set_measure_scale(dout->wlr_output->scale);
	clay_scroll_records_clear();
	Clay_BeginLayout();
	declare_scene(m);
	Clay_RenderCommandArray commands = Clay_EndLayout();

	for (int32_t i = 0; i < commands.length && n < cap; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		enum declare_kind kind = 0;
		void *object = declare_handle_get(
			declare_userdata_handle(cmd->userData), &kind);

		/* A leaf with no handle (the fullscreen backing) is not an
		 * object, and the wallpaper's is the Monitor, not a Lua object.
		 * A client declares a border leaf and a surface leaf, a drawin
		 * up to three image leaves; the object enters the order once, at
		 * its lowest leaf. */
		if (!object || kind == DECLARE_KIND_WALLPAPER
				|| (n > 0 && objects[n - 1] == object))
			continue;
		objects[n++] = object;
	}
	return n;
}

/* --- context lifecycle and the frame entry --- */

static int64_t
now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void
handle_clay_error(Clay_ErrorData error)
{
	/* A Clay error (arena exhaustion, duplicate id, command array
	 * overflow) is a bug, not a condition to ride out. */
	wlr_log(WLR_ERROR, "clay error %d: %.*s", error.errorType,
		error.errorText.length, error.errorText.chars);
	abort();
}

/* One band: an arena-backed Clay context and a render_state reconciling
 * into a fresh tree under parent. */
static void
declare_band_init(struct declare_band *band, struct wlr_output *wlr_output,
	struct wlr_scene_tree *parent)
{
	uint32_t arena_size = Clay_MinMemorySize();
	int width, height;

	wlr_output_effective_resolution(wlr_output, &width, &height);
	band->arena = malloc(arena_size);
	band->clay = Clay_Initialize(
		Clay_CreateArenaWithCapacityAndMemory(arena_size, band->arena),
		(Clay_Dimensions) { .width = width, .height = height },
		(Clay_ErrorHandler) { .errorHandlerFunction = handle_clay_error });
	/* Clay_Initialize left this the current context. Clay drops any
	 * element whose box lies entirely outside layoutDimensions
	 * (clay.h:2465), which saves draw calls in immediate mode and loses
	 * windows here. Boxes are output-local, but the nodes they reconcile
	 * into are not confined to the output: a floating client mid-drag and
	 * a drawin overhanging an edge render on the neighbor while their box
	 * is still relative to the output that declared them. wlr_scene does
	 * the per-output culling. */
	Clay_SetCullingEnabled(false);
	Clay_SetMeasureTextFunction(render_measure_text, NULL);
	band->tree = wlr_scene_tree_create(parent);
	band->render = render_create(band->tree);
}

static void
declare_band_wipe(struct declare_band *band)
{
	if (!band->clay)
		return;
	/* The Clay_Context lives inside the arena being freed. Clay keeps a
	 * global current-context pointer; left dangling, the next
	 * Clay_MinMemorySize or Clay_Initialize would read freed memory. */
	if (Clay_GetCurrentContext() == band->clay)
		Clay_SetCurrentContext(NULL);
	render_destroy(band->render, &client_hooks);
	wlr_scene_node_destroy(&band->tree->node);
	free(band->arena);
}

/* Layout dimensions, band position, and raster scale have one owner: this
 * function, run at band creation and on every updatemons pass. The frame
 * entry never re-derives them. */
static void
declare_band_update(struct declare_band *band, struct wlr_output *wlr_output,
	int lx, int ly)
{
	int width, height;

	if (!band->clay)
		return;
	wlr_output_effective_resolution(wlr_output, &width, &height);
	Clay_SetCurrentContext(band->clay);
	Clay_SetLayoutDimensions(
		(Clay_Dimensions) { .width = width, .height = height });
	render_set_position(band->render, lx, ly);
	render_set_scale(band->render, wlr_output->scale);
}

struct declare_output *
declare_output_create(struct wlr_output *wlr_output)
{
	struct declare_output *dout = calloc(1, sizeof(*dout));

	dout->wlr_output = wlr_output;
	declare_band_init(&dout->desktop, wlr_output, &scene->tree);
	/* Directly above the legacy layers, and below the drag icon and
	 * LyrBlock, both placed below LyrBlock at setup before any band. */
	wlr_scene_node_place_above(&dout->desktop.tree->node,
		&layers[LyrOverlay]->node);
	dout->dirty = true;
	return dout;
}

/* The lock scene, in some_activate_lua_lock()'s own order: the covers, then
 * the lock surface drawin on top. */
static void
declare_lock_scene(Monitor *m)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);

	for (int i = 0; i < cover_count; i++)
		if (covers[i] && declarable_drawin(covers[i], m))
			declare_drawin(covers[i], m, Z_LOCK_COVER);
	if (lock_surface && declarable_drawin(lock_surface, m))
		declare_drawin(lock_surface, m, Z_LOCK_SURFACE);
}

void
declare_lock_set_visible(bool on)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare)
			continue;
		/* Create the lock band on engage: wlroots appends new children
		 * topmost, so it lands above locked_bg and below any external
		 * session-lock tree created after it. */
		if (on && !m->declare->lock.clay) {
			declare_band_init(&m->declare->lock,
				m->declare->wlr_output, layers[LyrBlock]);
			declare_band_update(&m->declare->lock,
				m->declare->wlr_output, m->m.x, m->m.y);
		}
		if (m->declare->lock.render)
			render_set_enabled(m->declare->lock.render, on);
		declare_output_mark_dirty(m->declare);
	}
}

void
declare_output_destroy(struct declare_output *dout)
{
	declare_band_wipe(&dout->desktop);
	declare_band_wipe(&dout->lock);
	image_entry_set(&dout->wallpaper, NULL);
	free(dout);
}

void
declare_output_update(struct declare_output *dout, int lx, int ly)
{
	declare_band_update(&dout->desktop, dout->wlr_output, lx, ly);
	declare_band_update(&dout->lock, dout->wlr_output, lx, ly);
	declare_output_mark_dirty(dout);
}

void
declare_output_mark_dirty(struct declare_output *dout)
{
	dout->dirty = true;
	wlr_output_schedule_frame(dout->wlr_output);
}

/* Run the declare pass for every dirty output now. The poll function calls
 * this each loop iteration: input hit-testing reads the reconciled scene,
 * and a hidden or asleep output gets no frame events to rebuild it there.
 * The frame handler keeps its own call for marks that land in between.
 * Returns the scene mutations that took, so the caller can re-evaluate what
 * is under the pointer.
 */
int
declare_flush(void)
{
	Monitor *m;
	int mutations = 0, n;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare || !m->wlr_output->enabled)
			continue;
		n = declare_output_frame(m->declare, m, some_is_lua_locked());
		if (n > 0)
			mutations += n;
	}
	return mutations;
}

void
declare_mark_all_dirty(void)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link)
		if (m->declare)
			declare_output_mark_dirty(m->declare);
}

int
declare_output_frame(struct declare_output *dout, Monitor *m, bool lock_active)
{
	struct declare_band *band;
	int64_t declared, solved;

	if (!dout->dirty)
		return -1;
	in_frame = true;
	dout->dirty = false;

	/* While lua-locked, this output solves its lock scene instead; the
	 * desktop band keeps its last scene, occluded by locked_bg. The lock
	 * band normally exists already (declare_lock_set_visible creates it
	 * on engage); this covers outputs created mid-lock. */
	if (lock_active && !dout->lock.clay) {
		declare_band_init(&dout->lock, dout->wlr_output, layers[LyrBlock]);
		declare_band_update(&dout->lock, dout->wlr_output, m->m.x, m->m.y);
	}
	band = lock_active ? &dout->lock : &dout->desktop;

	band->declare_us = now_us();
	Clay_SetCurrentContext(band->clay);
	render_text_set_measure_scale(dout->wlr_output->scale);
	clay_scroll_records_clear();
	Clay_BeginLayout();
	if (lock_active)
		declare_lock_scene(m);
	else
		declare_scene(m);
	declared = now_us();
	Clay_RenderCommandArray commands = Clay_EndLayout();
	solved = now_us();

	band->commands = commands.length;
	band->mutations = render_reconcile(band->render, commands,
		&client_hooks, (Clay_BoundingBox) { 0, 0, m->m.width, m->m.height });
	band->reconcile_us = now_us() - solved;
	band->solve_us = solved - declared;
	band->declare_us = declared - band->declare_us;
	in_frame = false;
	return band->mutations;
}

/* --- the solved tree dump (somewm-client clay tree) ---
 *
 * One header line of counters per band and one line per retained node, in
 * draw order, read back from what the last reconcile retained (render.h).
 * Nothing here solves or declares: the dump reports the frame the output
 * drew. It doubles as a tree==scene check in release builds, where the
 * verifier is compiled out, by printing the renderer's own mismatch answer.
 */

static const char *
command_name(uint32_t type)
{
	switch (type) {
	case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:	return "RECTANGLE";
	case CLAY_RENDER_COMMAND_TYPE_BORDER:		return "BORDER";
	case CLAY_RENDER_COMMAND_TYPE_TEXT:		return "TEXT";
	case CLAY_RENDER_COMMAND_TYPE_IMAGE:		return "IMAGE";
	case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START:	return "SCISSOR_START";
	case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END:	return "SCISSOR_END";
	case CLAY_RENDER_COMMAND_TYPE_CUSTOM:		return "CUSTOM";
	default:					return "UNKNOWN";
	}
}

/* The widget node an element id names, walking the same path hashing the
 * declare pass used. The walk visits every node so the preorder index keeps
 * up with the id path; NULL when the id names no node in this tree. */
static const struct widget_node *
widget_node_for_id(struct widget_tree *d, size_t *i, Clay_ElementId id, uint32_t want)
{
	const struct widget_node *n = &d->nodes[(*i)++];
	const struct widget_node *hit = id.id == want ? n : NULL;

	for (uint16_t k = 0; k < n->children; k++) {
		const struct widget_node *c = widget_node_for_id(d, i,
			widget_child_id(d, *i, id, k), want);

		if (c && !hit)
			hit = c;
	}
	return hit;
}

/* What the node is. A leaf that carries no handle (a drawin's shadow and
 * border, the fullscreen backing, every SCISSOR marker) stands for no object
 * and says so. */
static void
dump_what(buffer_t *buf, uint32_t id, void *userdata)
{
	enum declare_kind kind = 0;
	void *object = declare_handle_get(declare_userdata_handle(userdata),
		&kind);

	if (!object) {
		buffer_adds(buf, "-");
		return;
	}
	switch (kind) {
	case DECLARE_KIND_CLIENT:
		buffer_addf(buf, "client %s", client_get_appid(object));
		break;
	case DECLARE_KIND_LAYER: {
		struct wlr_layer_surface_v1 *ls =
			((LayerSurface *)object)->layer_surface;

		buffer_addf(buf, "layer %s", ls->namespace ? ls->namespace : "?");
		break;
	}
	case DECLARE_KIND_WALLPAPER:
		buffer_addf(buf, "wallpaper %s",
			((Monitor *)object)->wlr_output->name);
		break;
	case DECLARE_KIND_TITLEBAR: {
		drawable_t *d = object;

		buffer_addf(buf, "titlebar %s", client_get_appid(d->owner.client));
		break;
	}
	case DECLARE_KIND_DRAWIN: {
		drawin_t *d = object;
		const struct widget_node *n = NULL;
		size_t i = 0;

		/* A converted drawin declares no leaf of its own, so every
		 * node carrying its handle is a widget node. The tree's root
		 * is the drawin's own box, and naming it as the drawin is what
		 * keeps a converted drawin in the dump under its own name. */
		if (d->widgets.nodes_len > 0)
			n = widget_node_for_id(&d->widgets, &i, widget_root_id(
				(uint32_t)declare_handle_for(d, DECLARE_KIND_DRAWIN)),
				id);
		if (n && n != d->widgets.nodes)
			buffer_addf(buf, "widget %s%s", n->cls ? n->cls : "-",
				n->raster ? " raster" : "");
		else
			buffer_addf(buf, "drawin screen %d %dx%d+%d+%d",
				d->screen ? d->screen->index : 0,
				d->width, d->height, d->x, d->y);
		break;
	}
	}
}

static void
dump_node(void *user, const struct render_node_view *v)
{
	buffer_t *buf = user;

	/* Only RECTANGLE carries the band it landed in (clay.h:2908). Every
	 * other command type is built without a zIndex (clay.h:2790, 2986) and
	 * would read as the bottom band, so those say they have none. Draw
	 * order is the line order either way. */
	buffer_addf(buf, "  %08x %-13s ", v->id, command_name(v->type));
	if (v->type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE)
		buffer_addf(buf, "z=%-4d ", v->z);
	else
		buffer_adds(buf, "z=-    ");
	buffer_addf(buf, "box %d,%d %dx%d rbox %d,%d %dx%d ",
		(int)v->box.x, (int)v->box.y,
		(int)v->box.width, (int)v->box.height,
		(int)v->rbox.x, (int)v->rbox.y,
		(int)v->rbox.width, (int)v->rbox.height);
	dump_what(buf, v->id, v->user_data);
	if (v->raster_bytes)
		buffer_addf(buf, " raster=%zu", v->raster_bytes);
	/* A SCISSOR marker and a clip mark realize no node by design; anything
	 * else that did not is a surface whose client died mid-frame. */
	if (v->clip_mark)
		buffer_adds(buf, " clip");
	else if (!v->has_node && v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_START
			&& v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_END)
		buffer_adds(buf, " no-node");
	if (v->rbox.width != v->box.width || v->rbox.height != v->box.height
			|| v->rbox.x != v->box.x || v->rbox.y != v->box.y)
		buffer_adds(buf, " [solved!=realized]");
	if (v->mismatch)
		buffer_adds(buf, " [tree!=scene]");
	buffer_adds(buf, "\n");
}

/* One axis of a node's sizing, as the tree declares it, not as it solved:
 * a number is CLAY_SIZING_FIXED, percent prints times 100 then % as in
 * Clay's inspector (third_party/clay.h:3320-3322), and fit and grow carry
 * the floor and ceiling when the node set them. A fixed root is the
 * drawin's geometry whatever the node says (declare_widget_subtree). */
static void
dump_sizing(buffer_t *buf, const struct widget_node *n, int axis)
{
	if (n->sizing[axis] == WIDGET_SIZING_FIXED) {
		buffer_addf(buf, "%g", n->size[axis]);
		return;
	}
	if (n->sizing[axis] == WIDGET_SIZING_PERCENT) {
		buffer_addf(buf, "%g%%", n->size[axis] * 100);
		return;
	}
	buffer_adds(buf, n->sizing[axis] == WIDGET_SIZING_GROW ? "grow" : "fit");
	if (n->min[axis] > 0)
		buffer_addf(buf, ">=%g", n->min[axis]);
	if (n->max[axis] > 0)
		buffer_addf(buf, "<=%g", n->max[axis]);
}

/* One line per node of a converted tree, in preorder, indented by depth:
 * what the tree says the node is and the box the last solve gave it.
 *
 * This walks the element tree, not the render commands, and that is the
 * point: Clay emits a RECTANGLE only for an element whose background has
 * alpha (clay.h:2778-2781), so a container that paints nothing is solved and
 * placed but appears in no command. The command list below can never show
 * those, and they are most of a widget tree. */
static size_t
dump_widget_node(buffer_t *buf, const struct widget_host *host, size_t i, Clay_ElementId id,
	int depth)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	Clay_ElementData data = Clay_GetElementData(id);
	size_t next = i + 1;

	buffer_addf(buf, "    %08x %*s%s", id.id, depth * 2, "",
		n->cls ? n->cls : "-");
	if (n->image) {
		buffer_addf(buf, " image %dx%d", cairo_image_surface_get_width(
			(cairo_surface_t *)n->image),
			cairo_image_surface_get_height((cairo_surface_t *)n->image));
		if (n->filter) {
			static const char *const filters[] = {
				"fast", "good", "best", "nearest", "bilinear"
			};
			buffer_addf(buf, " filter=%s", filters[n->filter - 1]);
		}
		if (n->natural)
			buffer_adds(buf, " natural");
	} else if (n->raster)
		buffer_adds(buf, " raster");
	else if (n->shape)
		buffer_adds(buf, " shape");
	if (!n->widget && !n->text && !n->image)
		buffer_adds(buf, " spacer");
	if (n->clip_opens)
		buffer_adds(buf, " clip");
	if (n->scroll)
		buffer_addf(buf, " scroll=%s", n->scroll == 1 ? "x" : "y");
	if (n->scrolled > 0)
		buffer_addf(buf, " scrolled=%g", n->scrolled);
	if (n->text) {
		buffer_addf(buf, " \"%.*s\" font=%u", (int)n->text_len,
			d->text + n->text_off, n->font);
	} else if (i == 0 && n->sizing[0] == WIDGET_SIZING_FIXED
			&& n->sizing[1] == WIDGET_SIZING_FIXED) {
		buffer_addf(buf, " w=%d h=%d", host->w, host->h);
	} else {
		buffer_adds(buf, " w=");
		dump_sizing(buf, n, 0);
		buffer_adds(buf, " h=");
		dump_sizing(buf, n, 1);
	}
	if (data.found)
		buffer_addf(buf, " box %d,%d %dx%d",
			(int)data.boundingBox.x, (int)data.boundingBox.y,
			(int)data.boundingBox.width,
			(int)data.boundingBox.height);
	else
		buffer_adds(buf, " box -");
	buffer_adds(buf, "\n");

	for (uint16_t k = 0; k < n->children; k++)
		next = dump_widget_node(buf, host, next,
			widget_child_id(d, next, id, k), depth + 1);
	return next;
}

/* Why a drawin paints itself whole, in the words widget.h names the reasons
 * with, so the dump answers the question rather than only reporting that one
 * image leaf drew. */
static void
dump_whole(buffer_t *buf, drawin_t *d)
{
	switch (d->widgets.state) {
	case WIDGET_NODES_NONE:
		buffer_adds(buf, " nothing converted");
		break;
	case WIDGET_NODES_MALFORMED:
		buffer_adds(buf, " malformed tree");
		break;
	case WIDGET_NODES_OVER_BUDGET:
		buffer_adds(buf, " over the output's element budget");
		break;
	default:
		buffer_adds(buf, " not compiled yet");
		break;
	}
	buffer_adds(buf, "\n");
}

static void
dump_drawin(buffer_t *buf, drawin_t *d)
{
	buffer_addf(buf, "  drawin screen %d %dx%d+%d+%d ",
		d->screen ? d->screen->index : 0, d->width, d->height,
		d->x, d->y);
	if (d->widgets.nodes_len == 0) {
		buffer_adds(buf, d->widgets.state == WIDGET_NODES_OVER_BUDGET
			|| d->widgets.state == WIDGET_NODES_MALFORMED ? "nothing:" : "whole:");
		dump_whole(buf, d);
		return;
	}
	buffer_addf(buf, "converted: %zu nodes, %zu raster",
		d->widgets.nodes_len, d->widgets.leaves_len);
	if (d->shape_radius > 0)
		buffer_addf(buf, ", radius %g", d->shape_radius);
	buffer_adds(buf, "\n");
	/* Clay's hashmap answers with the last box an id ever had, so a tree
	 * the declare pass has not reached yet would read back the boxes of
	 * the one it replaced (declare_widget_boxes says the same). */
	if (!d->widgets.declared) {
		buffer_adds(buf, "    not declared yet\n");
		return;
	}
	struct widget_host host;

	if (drawin_widget_host(d, &host))
		dump_widget_node(buf, &host, 0, widget_root_id(host.id), 0);
}

/* The drawins the band draws, converted or whole, on the same filters the
 * band's own declare pass applies, plus a drawin whose tree is over budget
 * or malformed: it shows nothing and has no content entry, and is listed so
 * the dump can say why. The lock band solves only while the session is
 * locked; before that its drawins are the desktop band's, and listing them
 * here too would name them twice. */
static void
dump_drawins(buffer_t *buf, Monitor *m, bool lock)
{
	if (lock && !session_is_locked())
		return;
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		if (lock ? !some_is_lock_drawin(d)
				: (session_is_locked()
					&& some_is_lock_drawin(d)))
			continue;
		if (!d->visible || !d->screen || d->screen->monitor != m
				|| (!d->content_entry.native
					&& d->widgets.state != WIDGET_NODES_OVER_BUDGET
					&& d->widgets.state != WIDGET_NODES_MALFORMED))
			continue;
		dump_drawin(buf, d);
	}
}

static void
dump_titlebars(buffer_t *buf, Monitor *m)
{
	static const char *const names[] = { "top", "right", "bottom", "left" };

	foreach(item, globalconf.clients) {
		Client *c = *item;

		if (c->mon != m || c->fullscreen || !declarable_client(c))
			continue;
		for (int bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++) {
			struct widget_host host;
			struct widget_tree *tree = &c->titlebar[bar].widgets;

			if (!c->titlebar[bar].size || (!tree->nodes_len && !c->titlebar[bar].content.native)
					|| !client_titlebar_host(c, c->titlebar[bar].drawable, &host))
				continue;
			buffer_addf(buf, "  titlebar %s %s %dx%d+%d+%d ",
				client_get_appid(c), names[bar], host.w, host.h,
				host.x + m->m.x, host.y + m->m.y);
			if (!tree->nodes_len) {
				buffer_adds(buf, "whole:\n");
				continue;
			}
			buffer_addf(buf, "converted: %zu nodes, %zu raster\n",
				tree->nodes_len, tree->leaves_len);
			if (tree->declared)
				dump_widget_node(buf, &host, 0, widget_root_id(host.id), 0);
			else
				buffer_adds(buf, "    not declared yet\n");
		}
	}
}

static void
dump_band(buffer_t *buf, struct declare_band *band, Monitor *m,
	const char *name, bool lock)
{
	struct wlr_output *o = m->wlr_output;
	Clay_Context *previous;

	if (!band->clay)
		return;
	buffer_addf(buf, "output %s band %s scale %.2f\n", o->name, name,
		o->scale);
	buffer_addf(buf, "  commands %d mutations %d nodes %zu raster_bytes %zu "
		"buffers %d declare %" PRId64 "us solve %" PRId64 "us "
		"reconcile %" PRId64 "us\n",
		band->commands, band->mutations,
		render_node_count(band->render),
		render_raster_bytes(band->render),
		render_buffers_created(band->render),
		band->declare_us, band->solve_us, band->reconcile_us);
	render_walk(band->render, dump_node, buf);
	/* The solved boxes come out of this band's own Clay context, which is
	 * a read of its hashmap; nothing here declares or solves. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	dump_drawins(buf, m, lock);
	if (!lock)
		dump_titlebars(buf, m);
	Clay_SetCurrentContext(previous);
}

char *
declare_dump(Monitor *only)
{
	buffer_t buf = BUFFER_INIT;
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare || (only && m != only))
			continue;
		dump_band(&buf, &m->declare->desktop, m, "desktop", false);
		dump_band(&buf, &m->declare->lock, m, "lock", true);
	}
	return buffer_detach(&buf);
}
