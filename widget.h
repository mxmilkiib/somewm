#ifndef SOMEWM_WIDGET_H
#define SOMEWM_WIDGET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <cairo.h>
#include <lua.h>

typedef struct drawin_t drawin_t;

/* One axis of a node's sizing, Clay's own types by name (Clay__SizingType,
 * clay.h): fit wraps the content, grow fills the parent, fixed is told. Fit
 * is Clay's default and this tree's: a node that says nothing fits. */
enum widget_sizing {
	WIDGET_SIZING_FIT = 0,
	WIDGET_SIZING_GROW,
	WIDGET_SIZING_FIXED,
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
	float size[2];       /* the fixed size, for WIDGET_SIZING_FIXED */
	float min[2];        /* Clay_SizingMinMax for fit and grow: the floor,
	                      * and the ceiling, 0 for none, which is Clay's own
	                      * convention (clay.h:1936) */
	float max[2];
	uint8_t align[2];    /* child alignment per axis, Clay_LayoutAlignmentX/Y */
	uint16_t gap;        /* between children, along the direction */
	bool vertical;       /* children top to bottom, else left to right */
	bool floating;       /* attached to the parent's top left, off the flow */
	bool raster;         /* an image leaf */
	/* A raster leaf whose pixels are the widget's own cairo surface (an
	 * imagebox's image), referenced rather than painted by Lua, with the
	 * aspect ratio Clay keeps (Clay_AspectRatioElementConfig). */
	const void *image;
	float aspect;
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

/* A tree with more nodes than this is refused rather than truncated. A busy
 * bar (taglist plus tasklist) is a few hundred nodes; Clay's default context
 * holds 8192 elements (clay.h:1019), shared by every drawin on the output. */
#define WIDGET_NODES_MAX 1024

/* Elements every converted tree on one output may take together. Clay's
 * context holds 8192 (clay.h:1019, allocated at 2151-2168) and every drawin
 * on the output declares into that one context, alongside its clients, layer
 * surfaces and leaves; the rest is the reserve for those, at up to three
 * elements per client. A tree that would take its output past this is refused
 * and the drawable paints itself whole, because exceeding Clay's own capacity
 * raises CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED (clay.h:780), which the
 * error handler treats as the bug it is and aborts on. */
#define WIDGET_NODES_OUTPUT_MAX 6144

/* Why d has to paint itself whole, as a mask of reasons, or 0 for a drawin
 * that can convert: shape_bounding and shape_clip are applied to the
 * drawable's own pixels (objects/drawin.c), which a converted node is no
 * longer part of, unless the two masks are one rounded rectangle
 * (drawin.h shape_radius), which the root element says as its corner
 * radius; shape_input's pass-through would be swallowed by a
 * converted node's scene rect, which takes input everywhere it draws; a
 * translucent drawin blends once as one layer, where a tree of nodes each
 * carrying the opacity would blend every overlap twice. */
enum {
	WIDGET_REFUSED_SHAPE_BOUNDING = 1 << 0,
	WIDGET_REFUSED_SHAPE_CLIP     = 1 << 1,
	WIDGET_REFUSED_SHAPE_INPUT    = 1 << 2,
	WIDGET_REFUSED_OPACITY        = 1 << 3,
};
unsigned widget_nodes_refused(drawin_t *d);

/* What the last widget_nodes_set() answered, kept so the tree dump can say
 * why a drawin paints itself whole rather than only that it does. Zero is a
 * drawin no redraw has compiled yet, so a field that was never written reads
 * as the fact it stands for. */
enum widget_nodes_state {
	WIDGET_NODES_UNTRIED = 0,
	WIDGET_NODES_CONVERTED,
	/* The compile step (lua/wibox/clay.lua) returned no tree at all. */
	WIDGET_NODES_NONE,
	/* widget_nodes_refused(), which names which reasons. */
	WIDGET_NODES_REFUSED,
	WIDGET_NODES_MALFORMED,
	WIDGET_NODES_OVER_BUDGET,
};

/* For the setters that change that answer: when it flips, drop the tree and
 * ask Lua for a complete repaint (property::surface on the drawable), so the
 * drawable moves between painting whole and converting without a widget
 * having to redraw first. udx is the drawin's stack index. */
void widget_nodes_gate(lua_State *L, drawin_t *d, int udx);

/* Read a tree from the table at absolute stack index idx (what
 * lua/wibox/clay.lua returns) and store it on d, replacing whatever was
 * there. Returns false and stores nothing when the tree is malformed or the
 * drawin is refused, which is Lua's signal to paint the whole drawable
 * itself. */
bool widget_nodes_set(lua_State *L, drawin_t *d, int idx);
void widget_nodes_clear(drawin_t *d);

/* Size each painted leaf's surface to the device size the solve gave it
 * (declare_widget_solve, in the order of the leaves that are not images),
 * and point each image leaf's entry at the widget's surface. Leaf surfaces
 * hold device pixels with no device scale set, like every other image
 * entry; a kept surface keeps its pixels, so Lua repaints only what its
 * dirty region says. */
void widget_leaves_size(drawin_t *d, int (*dev)[2]);

/* A new reference to leaf i's surface, for Lua to draw into and own the
 * reference of (the drawable.surface convention); NULL past the last leaf.
 * fresh says whether the surface is new since it was last handed out, so
 * holds no pixels yet. */
cairo_surface_t *widget_leaf_surface(drawin_t *d, size_t i, bool *fresh);

/* Bump the generation of every leaf whose index is a key in the table at
 * idx, so the renderer re-rasters exactly the leaves Lua redrew. */
void widget_leaves_drawn(lua_State *L, drawin_t *d, int idx);

#endif
