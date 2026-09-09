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
-- is the only solver of a converted tree, and no box is computed here. A
-- node is pure description, and its sizing is Clay's own, one of the three
-- types clay.h names: `fit` wraps the content, which is Clay's default
-- (CLAY_SIZING_FIT), `grow` fills the parent (CLAY_SIZING_GROW), and a
-- number is told (CLAY_SIZING_FIXED). A container says which of the first
-- two each child gets, in place of the `:fit` question the layout engine
-- asked; a widget's own preference (a forced size, a place that fills)
-- refines fit and never overrides grow, since fit is the content size and
-- that preference is the content.
--
-- A raster leaf is the one node the walk sizes. Clay measures nothing but
-- text (Clay_SetMeasureTextFunction), and an image element is a bare
-- pointer (Clay_ImageElementConfig), so a leaf is declared as Clay's own
-- image examples declare one: sized by its caller. The size is the leaf
-- widget's `:fit` at the drawin's bound, and an axis on which the widget
-- takes all it is offered grows instead, which is what that answer means.
--
-- @module wibox.clay
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gsurface = require("gears.surface")

local clay = {}

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
-- The spec stays on the node, so a leaf sized again merges again.
local function merge_sizing(node, spec)
    node.spec = spec
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
    -- A cap from either side stands, and the tighter of two.
    for _, k in ipairs { "wmax", "hmax" } do
        if spec[k] and node[k] then
            node[k] = math.min(spec[k], node[k])
        else
            node[k] = spec[k] or node[k]
        end
    end
end

--- Size a leaf node by its widget's `:fit` within a bound, as the engine
-- asked it: at compile time the bound is the drawin, and once Clay has
-- solved, the bound its parents leave it (`wibox.drawable` asks again). An
-- axis the widget takes whole grows, so Clay gives it what the layout
-- leaves. Returns whether the node changed.
--
-- @tparam table node The leaf's node.
-- @tparam wibox.widget widget The widget the leaf draws.
-- @tparam table context The widget context.
-- @tparam number width The bound's width.
-- @tparam number height The bound's height.
-- @treturn boolean Whether the node's sizing changed.
-- @staticfct wibox.clay.size_leaf
function clay.size_leaf(node, widget, context, width, height)
    local no_parent = base.no_parent_I_know_what_I_am_doing
    local fw, fh = base.fit_widget(no_parent, context, widget, width, height)
    -- A widget that takes all it is offered answers one more pixel when
    -- offered one more; a widget of its own size does not, even where that
    -- size is exactly the bound.
    local fw2 = base.fit_widget(no_parent, context, widget, width + 1, height)
    local _, fh2 = base.fit_widget(no_parent, context, widget, width, height + 1)
    local own = { w = fw2 > fw and "grow" or math.ceil(fw),
        h = fh2 > fh and "grow" or math.ceil(fh) }
    local was = { w = node.w, h = node.h, wmin = node.wmin, hmin = node.hmin }

    node.w, node.h, node.wmin, node.hmin = own.w, own.h, nil, nil
    if node.spec then
        merge_sizing(node, node.spec)
    end
    return node.w ~= was.w or node.h ~= was.h
        or node.wmin ~= was.wmin or node.hmin ~= was.hmin
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
        specs = { { image = surface, aspect = iw / ih, class = "image",
            w = math.ceil(iw * scale), h = math.ceil(ih * scale),
            refit = false } } }
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
-- `fg` as its source, at its `:fit` within the drawin.
local function leaf(st, widget, parent, fg)
    local node = { raster = true, class = class_name(widget),
        widget = widget, leaf = #st.leaves + 1 }

    -- Asked through the parent once, so the engine records that the
    -- parent's own fit depends on this widget's.
    base.fit_widget(parent, st.context, widget, st.width, st.height)
    clay.size_leaf(node, widget, st.context, st.width, st.height)
    st.leaves[node.leaf] = { widget = widget, fg = fg, node = node }
    return node
end

local compile_node

--- The nodes for a list of child specs: a widget's node with the sizing its
-- parent decided, or an empty element the parent asked for, which stands for
-- no widget and is left out of the box readback.
local function compile_specs(st, specs, parent, fg)
    local nodes = {}

    for i, spec in ipairs(specs) do
        local node

        if spec.widget then
            node = compile_node(st, spec.widget, parent, fg)
            merge_sizing(node, spec)
        else
            node = spec
            node.spacer = true
            node.children = spec.children
                and compile_specs(st, spec.children, parent, fg) or nil
            -- An image leaf takes its place among the leaves, with no
            -- hierarchy to draw it: the renderer shows its surface.
            if spec.image then
                node.leaf = #st.leaves + 1
                st.leaves[node.leaf] = { image = true, node = node }
            end
        end
        nodes[i] = node
    end
    return nodes
end

--- The node tree for `widget`.
function compile_node(st, widget, parent, fg)
    local node, node_fg = describe(widget, fg, st)

    if not node then
        return leaf(st, widget, parent, fg)
    end

    node.children = compile_specs(st, node.specs or {}, widget, node_fg or fg)
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
-- `image` (a cairo surface's native pointer), `aspect`, and its sizing. The
-- C side reads the description and ignores `widget` and `leaf`, which are
-- the drawable's.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.widget|nil root The drawable's widget.
-- @tparam table context The widget context.
-- @tparam number width The drawable's width, the bound every leaf is fit in.
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
        self.foreground_color)

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
