#ifndef SOMEWM_WIDGET_H
#define SOMEWM_WIDGET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <cairo.h>
#include <lua.h>

#include "render.h"

typedef struct drawin_t drawin_t;
typedef struct Monitor Monitor;

struct widget_tree {
	struct widget_node *nodes;
	size_t nodes_len;
	size_t scrolls;
	struct image_entry *leaves;
	size_t leaves_len;
	struct widget_shape *shapes;
	size_t shapes_len;
	char *text;
	size_t text_len;
	/* What the last compile answered (enum widget_nodes_state),
	 * for the tree dump. */
	uint8_t state;
	/* Whether the declare pass has put this tree in front of Clay yet.
	 * Clay's element hashmap is persistent and answers a lookup with the
	 * last box an id ever had (third_party/clay.h:1740-1754, 4283-4292),
	 * so without this a tree that changed since
	 * the last frame would read back the boxes of the one it replaced. */
	bool declared;
};

/* A converted widget tree at a box on an output. */
struct widget_host {
	struct widget_tree *tree;
	Monitor *m;
	uint32_t id;          /* The owner's declare handle id. */
	int x, y, w, h;       /* Output-local box. */
	float radius;        /* Shaped drawin corners, 0 for titlebars. */
	bool in_parent;
};

/* One axis of a node's sizing, Clay's own types by name (Clay__SizingType,
 * clay.h): fit wraps the content, grow fills the parent, fixed is told. Fit
 * is Clay's default and this tree's: a node that says nothing fits. */
enum widget_sizing {
	WIDGET_SIZING_FIT = 0,
	WIDGET_SIZING_GROW,
	WIDGET_SIZING_FIXED,
	WIDGET_SIZING_PERCENT,
};

/* One converted widget node, as lua/wibox/clay.lua describes it.
 *
 * The tree is stored in preorder: a node's subtree is the `children` nodes
 * that follow it, each with its own subtree. A node is pure description: what
 * it is (direction, sizing, gap, alignment, padding, colors, radius), never
 * where it is. A raster leaf carries a widget subtree the compile step could
 * not express, drawn by Lua into a surface of its own (the drawin's
 * widget_leaves, numbered in preorder too).
 *
 * Colors are straight alpha, 0-1, as everywhere else on this side; an alpha
 * of zero means the node draws no fill or no ring. */
struct widget_node {
	/* The widget's class name (wibox.widget.base's widget_name), interned
	 * so the whole struct still compares by memcmp. Only the tree dump
	 * (somewm-client clay tree) reads it: Clay carries no string from an
	 * element id to a render command. NULL for a node that stands for no
	 * widget. */
	const char *cls;
	uint16_t pad[4];     /* left, right, top, bottom */
	uint16_t bw[4];      /* border widths, same order */
	float bg[4];
	float border[4];
	float radius;
	uint8_t sizing[2];   /* enum widget_sizing per axis */
	float size[2];       /* the fixed size or percent */
	float min[2];        /* Clay_SizingMinMax for fit and grow: the floor,
	                      * and the ceiling, 0 for none, which is Clay's own
	                      * convention (clay.h:1936) */
	float max[2];
	uint8_t align[2];    /* child alignment per axis, Clay_LayoutAlignmentX/Y */
	uint16_t gap;        /* between children, along the direction */
	bool vertical;       /* children top to bottom, else left to right */
	float offset[2];     /* a floating node's offset from the parent's top left,
	                      * Clay_FloatingElementConfig.offset */
	bool floating;       /* attached to the parent's top left, off the flow */
	bool raster;         /* an image leaf */
	/* A raster leaf whose pixels are the widget's own cairo surface (an
	 * imagebox's image), referenced rather than painted by Lua. */
	const void *image;
	uint8_t filter;      /* cairo_filter_t + 1, 0 keeps cairo's default */
	bool natural;
	uint8_t scroll;      /* 0 none, 1 x, 2 y */
	float scrolled;
	uint16_t shape;
	float fill[4];
	struct render_gradient gradient;
	float stroke[4];
	float stroke_width;
	bool widget;         /* stands for a widget, so has a box Lua reads back */
	uint16_t children;
	/* The clip scope this node opens, numbered within the drawin from 1,
	 * and the one it is clipped by, 0 for none (render.h says how the
	 * renderer reads the two). The root opens one, so nothing draws
	 * outside the drawin, and so does a rounded container, so its
	 * children are cut to its arc as the container's own clip cut them.
	 * Numbered here rather than by Lua, from the tree's shape alone. */
	uint8_t clip_opens, clip_by;

	/* A text element (CLAY_TEXT), the child a converted textbox holds: the
	 * run in the drawin's widget_text buffer, and its Clay_TextElementConfig.
	 * fontSize is 0, the interned face carries its own size (render_text.h).
	 * A text node has no children and stands for no widget. */
	bool text;
	uint32_t text_off, text_len;
	uint16_t font;       /* render_font_intern's id */
	uint8_t wrap;        /* Clay_TextElementConfigWrapMode */
	uint8_t text_align;  /* Clay_TextAlignment */
	bool ellipsize;      /* RENDER_TEXT_ELLIPSIZE on the config's userData */
	float fg[4];
};

/* The text every text node of one drawin holds, together. Clay's render
 * commands slice it, so it lives until the next tree replaces it. */
#define WIDGET_TEXT_MAX 65536

/* Clip scopes a tree may open: a byte of the word numbers them (render.h). */
#define WIDGET_CLIPS_MAX 255

/* A tree with more nodes than this shows nothing. A busy bar (taglist plus
 * tasklist) is a few hundred nodes; Clay's default context holds 8192
 * elements (clay.h:1019), shared by every drawin on the output. */
#define WIDGET_NODES_MAX 1024

/* Elements every converted tree on one output may take together. Clay's
 * context holds 8192 (clay.h:1019, allocated at 2151-2168) and every drawin
 * on the output declares into that one context, alongside its clients, layer
 * surfaces and leaves; the rest is the reserve for those, at up to three
 * elements per client. A tree past this budget shows nothing. Exceeding capacity
 * raises CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED (clay.h:780), which the
 * error handler treats as the bug it is and aborts on. */
#define WIDGET_NODES_OUTPUT_MAX 6144

/* Scroll records per context (third_party/clay.h:2194). */
#define WIDGET_SCROLLS_OUTPUT_MAX 10

/* What the last widget_nodes_set() answered, kept so the tree dump can say
 * why a drawin paints itself whole rather than only that it does. Zero is a
 * drawin no redraw has compiled yet, so a field that was never written reads
 * as the fact it stands for. */
enum widget_nodes_state {
	WIDGET_NODES_UNTRIED = 0,
	WIDGET_NODES_CONVERTED,
	/* The compile step (lua/wibox/clay.lua) returned no tree at all. */
	WIDGET_NODES_NONE,
	WIDGET_NODES_MALFORMED,
	WIDGET_NODES_OVER_BUDGET,
};

/* Replace the stored tree with the compiled table at idx. False with NONE
 * paints whole; MALFORMED or OVER_BUDGET shows nothing. */
bool widget_nodes_set(lua_State *L, struct widget_tree *d, Monitor *m, int idx);
void widget_nodes_clear(struct widget_tree *d);

/* Size each painted leaf's surface to the device size the solve gave it
 * (declare_widget_solve, in the order of the leaves that are not images),
 * and point each image leaf's entry at the widget's surface. Leaf surfaces
 * hold device pixels with no device scale set, like every other image
 * entry; a kept surface keeps its pixels, so Lua repaints only what its
 * dirty region says. */
void widget_leaves_size(struct widget_tree *d, int (*dev)[2]);

/* A new reference to leaf i's surface, for Lua to draw into and own the
 * reference of (the drawable.surface convention); NULL past the last leaf.
 * fresh says whether the surface is new since it was last handed out, so
 * holds no pixels yet. */
cairo_surface_t *widget_leaf_surface(struct widget_tree *d, size_t i, bool *fresh);

/* Bump the generation of every leaf whose index is a key in the table at
 * idx, so the renderer re-rasters exactly the leaves Lua redrew. */
bool widget_leaves_drawn(lua_State *L, struct widget_tree *d, int idx);

#endif
