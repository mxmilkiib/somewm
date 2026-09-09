---------------------------------------------------------------------------
--- Compile a drawable's widget tree into Clay declarations.
--
-- The declare pass (declare.c) draws a drawin from the tree this module
-- returns: one Clay element per widget the compile step can express, and one
-- raster leaf per subtree it cannot, drawn by cairo into the leaf's own
-- surface (widget.c) and shown at the box Clay solves for it. When nothing
-- converts the drawable paints itself whole, as it always did.
--
-- The walk descends the widget tree itself, not a laid-out hierarchy: Clay
-- is the only solver of a converted tree, and the walk computes no box,
-- only the offer each node passes down. A node's sizing is one of the four
-- types clay.h names: `fit` wraps the content, which is Clay's default
-- (CLAY_SIZING_FIT), `grow` fills the parent (CLAY_SIZING_GROW), a number
-- is told (CLAY_SIZING_FIXED), and a table `{ percent = p }` is a share of
-- the parent (CLAY_SIZING_PERCENT, clay.h:66-72, 289-297). A container
-- says which of the first two each child gets, in place of the
-- `:fit` question the layout engine asked; a widget's own preference (a
-- forced size, a place that fills) refines fit and never overrides grow,
-- since fit is the content size and that preference is the content.
--
-- The offer is the box the engine's `:fit` was asked with: the drawin at
-- the root, less each node's padding on the way down. Clay measures
-- nothing but text (Clay_SetMeasureTextFunction, clay.h:889), and an image
-- element is a bare pointer (Clay_ImageElementConfig, clay.h:414-416), so
-- a node that says `aspect` or `square` is told both sizes from the offer,
-- a forced axis standing. A cap of `"offer"` (`wmax`, `hmax`) is the
-- offer on that axis, for a node whose content it cuts rather than
-- outgrows. A raster leaf is sized by its widget's `:fit` at the offer,
-- and an axis on which the widget takes the whole offer grows instead,
-- which is what that answer means.
--
-- @module wibox.clay
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local gsurface = require("gears.surface")

local cairo = require("lgi").cairo
local clay = {}
local probe = cairo.Context(cairo.ImageSurface(cairo.Format.A8, 1, 1))

--- Record a shape path in logical pixels, offset by dx and dy.
function clay.shape_ops(shape, w, h, dx, dy, ...)
    probe:new_path()
    local ops = {}
    local kinds = { MOVE_TO = 0, LINE_TO = 1, CURVE_TO = 2, CLOSE_PATH = 3 }
    local function append_path()
        for kind, points in probe:copy_path():pairs() do
            ops[#ops + 1] = kinds[kind]
            for _, point in ipairs(points) do
                ops[#ops + 1] = point.x + (dx or 0)
                ops[#ops + 1] = point.y + (dy or 0)
            end
        end
    end
    local recorder = setmetatable({}, { __index = function(_, name)
        if name == "stroke" or name == "fill" then
            return function()
                append_path()
                probe:new_path()
            end
        elseif name == "stroke_preserve" or name == "fill_preserve" then
            return append_path
        end
        return function(_, ...)
            return probe[name](probe, ...)
        end
    end })
    shape(recorder, w, h, ...)
    append_path()
    return ops
end

--- The corner radius a shape stands for, or nil for one Clay cannot name.
-- A shape is an arbitrary painter: the two gears shapes that are rectangles
-- are known by identity, and any other function by the path it draws;
-- `rounded_bar` and the rest keep drawing themselves.

local function same_path(a, b)
    if #a ~= #b then
        return false
    end
    for i, value in ipairs(a) do
        if value ~= b[i] then
            return false
        end
    end
    return true
end

--- The radius a shape function draws when its path is
-- gears.shape.rounded_rect's, which is what a theme's `function(cr, w, h)
-- gears.shape.rounded_rect(cr, w, h, r) end` draws: the same path at two
-- sizes, with the radius read off the path's first point (0, r). Cached
-- per function; false for one that draws anything else.
local shape_radii = setmetatable({}, { __mode = "k" })

local function closure_radius(shape)
    local r = shape_radii[shape]

    if r == nil then
        local w, h = 160, 96
        local path = clay.shape_ops(shape, w, h)

        r = false
        if path[1] == 0 and path[2] == 0 then
            local radius = path[3]

            if same_path(path, clay.shape_ops(gshape.rounded_rect, w, h, 0, 0, radius))
                    and same_path(clay.shape_ops(shape, 2 * w, 2 * h),
                        clay.shape_ops(gshape.rounded_rect, 2 * w, 2 * h, 0, 0, radius)) then
                r = radius
            end
        end
        shape_radii[shape] = r
    end
    return r or nil
end

local function shape_radius(shape, args)
    if shape == nil or shape == gshape.rectangle then
        return 0
    end
    if shape == gshape.rounded_rect then
        local r = args and args[1] or 10

        return (type(r) == "number" and r >= 0) and r or nil
    end
    if type(shape) == "function" then
        return closure_radius(shape)
    end
    return nil
end

clay.shape_radius = shape_radius

--- The straight-alpha components of a solid color pattern, or nil for a
-- gradient, a surface pattern, or no color at all. A Clay color is one flat
-- fill; anything else has to keep painting itself.
local function solid_rgba(col)
    if not col then
        return nil
    end

    local pattern = gcolor(col)

    if pattern:get_type() ~= "SOLID" then
        return nil
    end

    local status, r, g, b, a = pattern:get_rgba()

    if status ~= "SUCCESS" then
        return nil
    end

    return { r, g, b, a }
end

--- Clay pads, gaps and border widths are whole uint16 pixels
-- (clay.h:330-335 padding, 344 childGap, 533-541 border widths).
local function whole(v)
    return type(v) == "number" and v >= 0 and v <= 65535 and v % 1 == 0
end

--- Properties every widget carries that a converted node cannot express:
-- `visible` and `opacity` are applied by `wibox.hierarchy`, which a converted
-- node no longer passes through. Each keeps the widget drawing itself.
local function common_convertible(w)
    local p = w._private

    return p.visible ~= false and (p.opacity == nil or p.opacity == 1)
end

--- The spec for a container's only child: the whole padded box, which is
-- what `margin:layout` and `background:layout` place it at.
local function whole_box(widget)
    return widget and { { widget = widget, w = "grow", h = "grow" } } or {}
end

--- The parent's sizing for a child, over the child's own. Grow stands, and
-- a size the child gave becomes its floor (Clay_SizingMinMax.min): the
-- child fills what it is given, and a parent that wraps its content still
-- counts that size, as the engine's `:fit` counted it through a container
-- that hands its child the whole box. Fit gives way to what the child said.
-- A floor from either side stands, and the larger of two.
local function merge_sizing(node, spec)
    for _, k in ipairs { "w", "h" } do
        if spec[k] == "grow" then
            if type(node[k]) == "number" then
                node[k .. "min"] = node[k]
            end
            node[k] = "grow"
        elseif node[k] == nil then
            node[k] = spec[k]
        end
    end
    for _, k in ipairs { "wmin", "hmin" } do
        if spec[k] and node[k] then
            node[k] = math.max(spec[k], node[k])
        else
            node[k] = spec[k] or node[k]
        end
    end
    -- A cap from either side stands, and the tighter of two.
    for _, k in ipairs { "wmax", "hmax" } do
        if spec[k] and node[k] then
            node[k] = math.min(spec[k], node[k])
        else
            node[k] = spec[k] or node[k]
        end
    end
end

-- Size a raster leaf by its widget's fit at the offer. An axis the widget
-- takes whole grows; an axis of its own size is told.
local function size_leaf(node, widget, context, width, height)
    local no_parent = base.no_parent_I_know_what_I_am_doing
    local fw, fh = base.fit_widget(no_parent, context, widget, width, height)
    -- A widget that takes all it is offered answers one more pixel when
    -- offered one more; a widget of its own size does not, even where that
    -- size is exactly the bound.
    local fw2 = base.fit_widget(no_parent, context, widget, width + 1, height)
    local _, fh2 = base.fit_widget(no_parent, context, widget, width, height + 1)
    node.w = fw2 > fw and "grow" or math.ceil(fw)
    node.h = fh2 > fh and "grow" or math.ceil(fh)
end

--- awful.widget.systray_icon -> an element centering one image leaf: the
-- item's pixmap, or the icon file its name resolves to, at the slot's
-- square scaled to keep the icon's aspect, as `systray_icon:draw` paints
-- it. A hovered, urgent or overlaid icon, or one under a
-- `beautiful.systray_icon_style`, draws more than an image, and keeps
-- drawing itself.
function clay.systray_icon(w)
    local p = w._private
    local item = p.item

    if not item or p.is_hovered or beautiful.systray_icon_style
            or item.status == "NeedsAttention" or item.overlay_icon then
        return nil
    end

    local size = p.forced_size or 24
    local sw, sh = p.forced_width or size, p.forced_height or size
    local surface, iw, ih = item:_icon_surface()

    if not surface then
        -- The icon file, loaded once per path so the surface the leaf
        -- references stays the same object across compiles.
        local path = p.current_icon

        if type(path) ~= "string" then
            return nil
        end
        if not p.clay_icon or p.clay_icon.path ~= path then
            local loaded = gsurface.load_silently(path)

            if not loaded then
                return nil
            end
            p.clay_icon = { path = path, surface = loaded }
        end
        surface = p.clay_icon.surface._native
        iw, ih = p.clay_icon.surface.width, p.clay_icon.surface.height
    end
    if not (iw > 0 and ih > 0) then
        return nil
    end

    local scale = math.min(sw / iw, sh / ih)

    return { w = sw, h = sh, align = { x = "center", y = "center" },
        specs = { { image = surface, class = "image",
            w = math.ceil(iw * scale), h = math.ceil(ih * scale) } } }
end

--- wibox.widget.systray -> the fixed layout it is, with the padding and
-- the background its overrides add (`beautiful.systray_paddings`,
-- `beautiful.bg_systray`) and the least size its `:fit` answers. More than
-- one row (`beautiful.systray_max_rows`) is a grid, which keeps the tray
-- drawing itself.
function clay.systray(w)
    local p = w._private
    local padding = beautiful.systray_paddings or 0
    local rows = math.floor(tonumber(beautiful.systray_max_rows) or 1)
    local spacing = p.spacing or 0
    local size = w.base_size or 24

    if rows > 1 or not whole(padding) or not whole(spacing)
            or (spacing ~= 0 and p.spacing_widget) then
        return nil
    end

    local along, across = "w", "h"

    if p.dir == "y" then
        along, across = "h", "w"
    end

    local node = { dir = p.dir, gap = spacing, specs = {},
        pad = { padding, padding, padding, padding },
        [along .. "min"] = padding * 2 + size }

    if beautiful.bg_systray then
        node.bg = solid_rgba(beautiful.bg_systray)
        if not node.bg then
            return nil
        end
    end
    for i, child in ipairs(p.widgets) do
        node.specs[i] = { widget = child, [across] = "grow" }
    end
    return node
end

--- Register the describer for one widget.
-- @tparam wibox.widget w The widget.
-- @tparam function describer The describer, as the class table's entries.
-- @tparam string name The widget's class, for the `somewm-client clay
--  tree` dump, where `widget_name` names the class it was built from.
-- @staticfct wibox.clay.describe_widget
function clay.describe_widget(w, describer, name)
    w._clay = { describe = describer, fit = w.fit, name = name }
end


--- The node a widget compiles to, plus any foreground it puts in force, or
-- nil for a widget that keeps drawing itself. `node.specs` is how the widget
-- sizes its children. A forced size is the widget's own `:fit` answer,
-- whatever its class would have said.
local function describe(w, fg, st)
    local record = w._clay

    -- A subclass overriding fit rasters, so no describer checks fit itself.
    if not record or w.fit ~= record.fit or not common_convertible(w) then
        return nil
    end

    local node, node_fg = record.describe(w, fg, st)

    if node then
        node.w = w._private.forced_width or node.w
        node.h = w._private.forced_height or node.h
    end
    return node, node_fg
end

--- The widget's class, for the `somewm-client clay tree` dump.
--
-- `gears.object.modulename` derives `widget_name` from the source path and
-- only trims it at a `lib/` directory; somewm installs its library under
-- `lua/`, so the name arrives with the path still in front of it.
local function class_name(w)
    local name = w._clay and w._clay.name or w.widget_name

    if not name then
        return nil
    end
    return (name:gsub("^.*%.lua%.", ""):gsub("^[^%a]+", ""))
end

--- A raster leaf for the subtree at `widget`: the widget draws itself, with
-- `fg` as its source, at its `:fit` within the offer.
local function leaf(st, widget, parent, fg, offer)
    local node = { raster = true, class = class_name(widget),
        widget = widget, leaf = #st.leaves + 1 }

    -- Asked through the parent once, so the engine records that the
    -- parent's own fit depends on this widget's.
    base.fit_widget(parent, st.context, widget, offer.w, offer.h)
    size_leaf(node, widget, st.context, offer.w, offer.h)
    st.leaves[node.leaf] = { widget = widget, fg = fg, node = node }
    return node
end

-- Resolve a shape's size from the offer before forced axes override it.
local function resolve_size(node, offer)
    for _, k in ipairs { "w", "h" } do
        if node[k .. "max"] == "offer" then
            node[k .. "max"] = offer[k]
        end
    end
    if node.aspect or node.square then
        local w = math.min(offer.w, node.wmax or math.huge)
        local h = math.min(offer.h, node.hmax or math.huge)
        local rw, rh

        if node.aspect then
            rw = math.ceil(math.min(w, h * node.aspect))
            rh = math.ceil(math.min(h, w / node.aspect))
        else
            rw, rh = math.min(w, h), math.min(w, h)
        end
        node.w = type(node.w) == "number" and node.w or rw
        node.h = type(node.h) == "number" and node.h or rh
    end
end

-- The node's box at most, and the offer its padding leaves for children.
-- Floating children take the full box (third_party/clay.h:2224-2237).
local function node_offer(node, offer)
    local box = {}

    for _, k in ipairs { "w", "h" } do
        local size = node[k]

        box[k] = math.min(type(size) == "number" and size
            or type(size) == "table" and offer[k] * size.percent or offer[k],
            node[k .. "max"] or math.huge)
    end
    local pad = node.pad or { 0, 0, 0, 0 }

    return { w = math.max(0, box.w - pad[1] - pad[2]),
        h = math.max(0, box.h - pad[3] - pad[4]) }, box
end

local compile_node

--- The nodes for a list of child specs: a widget's node with the sizing its
-- parent decided, or an empty element the parent asked for, which stands for
-- no widget and is left out of the box readback.
local function compile_specs(st, specs, parent, fg, offer, box)
    local nodes = {}

    for i, spec in ipairs(specs) do
        local node
        local bound = spec.float and box or offer

        resolve_size(spec, bound)
        local inner, spec_box = node_offer(spec, bound)

        if spec.widget then
            node = compile_node(st, spec.widget, parent, fg, spec_box)
            merge_sizing(node, spec)
        else
            node = spec
            node.spacer = true
            -- An image leaf takes its place among the leaves, with no
            -- hierarchy to draw it: the renderer shows its surface.
            if spec.image then
                node.leaf = #st.leaves + 1
                st.leaves[node.leaf] = { image = true, node = node }
            end
            node.children = spec.children
                and compile_specs(st, spec.children, parent, fg, inner, spec_box) or nil
        end
        nodes[i] = node
    end
    return nodes
end

--- The node tree for `widget`.
function compile_node(st, widget, parent, fg, offer)
    local node, node_fg = describe(widget, fg, st)

    if not node then
        return leaf(st, widget, parent, fg, offer)
    end

    if node.fit then
        offer = { w = node.wmax or 9999, h = node.hmax or 9999 }
    end
    resolve_size(node, offer)
    local inner, box = node_offer(node, offer)

    node.children = compile_specs(st, node.specs or {}, widget, node_fg or fg, inner, box)
    node.specs = nil
    node.class = class_name(widget)
    node.widget = widget
    return node
end

--- Add a wrapper class that passes through to one child: its `:layout`
-- hands the widget under `field` the whole box and its `:fit` is that
-- widget's, so the node is that child's spec and nothing else. What
-- awful.widget.taglist and tasklist are around their `base_layout`; they
-- register here, since awful depends on wibox and not the other way.
--
-- @tparam table class The widget class, with `fit` and `layout`.
-- @tparam string field The `_private` field holding the child.
-- @staticfct wibox.clay.passthrough
function clay.passthrough(class, field)
    class._clay = { fit = class.fit, describe = function(w)
        if w.layout ~= class.layout then
            return nil
        end
        return { specs = whole_box(w._private[field]) }
    end }
end

--- Add a widget class with its describer, for a class defined outside
-- wibox that draws itself in a way the tree can say (awful.widget's
-- systray_icon). An instance overriding `:draw` fails the class's identity
-- check and keeps drawing itself.
-- @tparam table class The widget class, with `fit` and `draw`.
-- @tparam function describer The describer, as the class table's entries.
-- @staticfct wibox.clay.describe_class
function clay.describe_class(class, describer)
    class._clay = { fit = class.fit, describe = function(w, fg, st)
        if w.draw ~= class.draw then
            return nil
        end
        return describer(w, fg, st)
    end }
end

--- Compile a drawable's widget tree.
--
-- Returns the node tree, rooted at the drawable's own background, and the
-- raster leaves in the tree's preorder, each with the widget it draws, the
-- foreground in force and its node. Returns nil when nothing converts, which
-- leaves the drawable on the path it has always taken: painted whole.
--
-- A node is a table with any of `pad`, `bg`, `border`, `bw`, `radius`, the
-- sizing `w` and `h` (`"fit"` or absent, `"grow"`, or a fixed number) with
-- `wmin`, `hmin`, `wmax` and `hmax` as the floor and ceiling of fit and
-- grow, `dir` ("y" for top to bottom), `gap`,
-- `align` (`x` and `y`, as wibox.container.place names them), `float`
-- (attached to the parent's top left, off the flow), `raster` for a leaf
-- with `leaf` as its index, `spacer` for an element that stands for no
-- widget, `class` (the widget's `widget_name`, for the `somewm-client clay
-- tree` dump), `widget`, and `children`. A text element is a node with
-- `text`, `font` (an id from `awesome._clay_font`), `color`, `wrap`,
-- `halign` and `ellipsize`, and nothing else; an image leaf is a node with
-- `image` (a cairo surface's native pointer) and its sizing. The compile
-- step resolves `aspect` and `square` into sizes. The C side ignores these
-- words and `widget` and `leaf`, which are the drawable's.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.widget|nil root The drawable's widget.
-- @tparam table context The widget context.
-- @tparam number width The drawable's width, the root's offer.
-- @tparam number height The drawable's height.
-- @treturn[1] table The node tree.
-- @treturn[1] table The raster leaves, in preorder.
-- @treturn[2] nil Nothing converted.
function clay.compile(self, root, context, width, height)
    -- A background image is a painter over the whole drawable, with no Clay
    -- equivalent short of rastering it, which is what painting whole does.
    if not root or self.background_image
            or not root._clay or root.fit ~= root._clay.fit then
        return nil
    end

    -- The drawable's own background becomes the outermost rectangle, so it
    -- has to be one Clay can name before anything inside it can convert. A
    -- transparent one draws nothing and still takes input over the whole
    -- box, as a wibox does (widget.h clip_opens): an awful.tooltip's wibox
    -- is transparent, with its background drawn by a container inside.
    local base_rgba = solid_rgba(self.background_color)

    if not base_rgba then
        return nil
    end

    local st = { leaves = {}, context = context, width = width, height = height }
    local node = compile_node(st, root, base.no_parent_I_know_what_I_am_doing,
        self.foreground_color, { w = width, h = height })

    -- The root's class matched but its properties did not: the leaf still
    -- covers every pixel it did, so there is nothing to gain and a whole
    -- path to keep off.
    if node.raster then
        return nil
    end

    -- The widget gets the whole drawin, as the engine gave it. The root is
    -- the drawin's box, told (CLAY_SIZING_FIXED), unless the widget sizes
    -- the drawin (an awful.popup follows its content, `node.fit`): then
    -- the root wraps the widget (CLAY_SIZING_FIT) within the widget's
    -- limits, and the drawin takes the box Clay solves for it.
    local tree = { bg = base_rgba, radius = 0, class = "drawable",
        w = width, h = height, children = { node } }

    merge_sizing(node, { w = "grow", h = "grow" })
    if node.fit then
        tree.fit, node.fit = node.fit, nil
        tree.w, tree.h = "fit", "fit"
        tree.wmin, tree.wmax = node.wmin, node.wmax
        tree.hmin, tree.hmax = node.hmin, node.hmax
        node.wmin, node.wmax, node.hmin, node.hmax = nil, nil, nil, nil
    else
        -- A tree wider than its drawin lays out at its own size and is cut
        -- to the drawin, never squeezed into it: Clay compresses the
        -- children of a parent they overflow (clay.h:2300-2311), so the
        -- widget is a floating element, sized by its own content and
        -- clamped by nothing but its floor (clay.h:2224-2239), at least
        -- the drawin's box.
        node.float = true
        node.w, node.h = "fit", "fit"
        node.wmin = math.max(width, node.wmin or 0)
        node.hmin = math.max(height, node.hmin or 0)
    end
    return tree, st.leaves
end

clay.solid_rgba = solid_rgba
clay.whole = whole
clay.whole_box = whole_box

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
