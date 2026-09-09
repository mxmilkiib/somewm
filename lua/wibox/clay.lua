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
local lgi = require("lgi")
local lgi_core = require("lgi.core")
local Pango = lgi.Pango
local cairo = lgi.cairo
local textbox_class = require("wibox.widget.textbox")
local imagebox_class = require("wibox.widget.imagebox")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local gsurface = require("gears.surface")
local margin_class = require("wibox.container.margin")
local background_class = require("wibox.container.background")
local place_class = require("wibox.container.place")
local constraint_class = require("wibox.container.constraint")
local fixed_class = require("wibox.layout.fixed")
local flex_class = require("wibox.layout.flex")
local align_class = require("wibox.layout.align")
local stack_class = require("wibox.layout.stack")
local capi = { awesome = awesome }

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

--- The corner radius a shape stands for, or nil for one Clay cannot name.
-- A shape is an arbitrary painter: the two gears shapes that are rectangles
-- are known by identity, and any other function by the path it draws;
-- `rounded_bar` and the rest keep drawing themselves.

-- A context for a shape function to draw its path on, for the path alone.
local probe = cairo.Context(cairo.ImageSurface(cairo.Format.A8, 1, 1))

local function shape_path(shape, w, h, r)
    probe:new_path()
    shape(probe, w, h, r)
    return probe:copy_path()
end

local function same_path(a, b)
    if a.num_data ~= b.num_data then
        return false
    end

    local next_b = b:pairs()

    for kind, points in a:pairs() do
        local kind_b, points_b = next_b()

        if kind ~= kind_b then
            return false
        end
        for i, point in ipairs(points) do
            if point.x ~= points_b[i].x or point.y ~= points_b[i].y then
                return false
            end
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
        local path = shape_path(shape, w, h)
        local kind, points = path:pairs()()

        r = false
        if kind == "MOVE_TO" and points[1].x == 0 then
            local radius = points[1].y

            if same_path(path, shape_path(gshape.rounded_rect, w, h, radius))
                    and same_path(shape_path(shape, 2 * w, 2 * h),
                        shape_path(gshape.rounded_rect, 2 * w, 2 * h, radius)) then
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

--- wibox.container.margin -> Clay padding, and the margin color -> a Clay
-- border of the same widths, which covers exactly the ring `margin:draw`
-- fills with the even-odd rule.
local function describe_margin(w)
    local p = w._private

    if w.layout ~= margin_class.layout or w.draw ~= margin_class.draw then
        return nil
    end
    -- draw_empty=false makes an empty margin no size at all, where Clay's
    -- fit wraps the padding.
    if p.draw_empty == false then
        return nil
    end

    local pad = { p.left or 0, p.right or 0, p.top or 0, p.bottom or 0 }

    for _, v in ipairs(pad) do
        if not whole(v) then
            return nil
        end
    end

    local node = { pad = pad, specs = whole_box(p.widget) }

    if p.color then
        local rgba = solid_rgba(p.color)

        if not rgba then
            return nil
        end
        node.border, node.bw = rgba, pad
    end

    return node
end

--- wibox.container.background -> a rectangle color, a corner radius and a
-- border.
--
-- Clay draws a border inside the element box without moving its children,
-- which is what `border_strategy = "none"` does; "inner" adds the padding
-- that shrinks them.
local function describe_background(w)
    local p = w._private

    if w.layout ~= background_class.layout
            or w.before_draw_children ~= background_class.before_draw_children
            or w.after_draw_children ~= background_class.after_draw_children then
        return nil
    end
    -- A background image is a painter over the whole box, with no Clay
    -- equivalent short of rastering it, which is what a leaf does.
    if p.bgimage then
        return nil
    end

    local bw = p.shape_border_width or 0

    if not whole(bw) then
        return nil
    end

    local radius = shape_radius(p.shape, p.shape_args)

    if not radius then
        return nil
    end
    -- A rounded shape and a border together do not draw the ring Clay draws:
    -- the cairo path is inset by the border width, so the visible outer
    -- corner is rounder than the shape names. Rather than approximate it,
    -- the container keeps drawing itself.
    if radius > 0 and bw > 0 then
        return nil
    end

    local node = { radius = radius, specs = whole_box(p.widget) }

    if p.background then
        node.bg = solid_rgba(p.background)
        if not node.bg then
            return nil
        end
    end

    if bw > 0 then
        -- No color at all is black, which is what gears.color makes of nil.
        node.border = solid_rgba(p.shape_border_color or p.foreground
            or beautiful.fg_normal or "#000000")
        if not node.border then
            return nil
        end
        node.bw = { bw, bw, bw, bw }
        if p.border_strategy == "inner" then
            node.pad = { bw, bw, bw, bw }
        end
    end

    -- A background's fg is the source its children draw with, so it rides
    -- alongside the node rather than in it: a leaf takes the innermost one.
    return node, p.foreground
end

--- What wibox.layout.fixed and flex share: a layout direction and a child
-- gap, which Clay's childGap (clay.h:344) carries only when the spacing is
-- whole, not negative, and not a spacing widget, which is a widget placed
-- between the children rather than a gap.
-- Returns the node and the axis names along and across the direction, or
-- nil when the layout keeps drawing itself.
local function describe_linear(w, class)
    local p = w._private
    local spacing = p.spacing or 0

    if w.layout ~= class.layout or not whole(spacing)
            or (spacing ~= 0 and p.spacing_widget) then
        return nil
    end
    if p.dir == "y" then
        return { dir = "y", gap = spacing, specs = {} }, "h", "w"
    end
    return { dir = "x", gap = spacing, specs = {} }, "w", "h"
end

--- wibox.layout.fixed: every child at its content size along the direction,
-- which is the `:fit` the engine asked it for, and the whole size across.
-- The last child grows along too when `fill_space` is set.
--
-- Clay's childGap is added between every pair of children whatever their
-- size (clay.h:3080-3082), where the engine skipped the spacing of a child
-- whose `:fit` was zero.
local function describe_fixed(w)
    local node, along, across = describe_linear(w, fixed_class)

    if not node then
        return nil
    end

    local p = w._private

    for i, child in ipairs(p.widgets) do
        local spec = { widget = child, [across] = "grow" }

        if i == #p.widgets and p.fill_space then
            spec[along] = "grow"
        end
        node.specs[i] = spec
    end
    return node
end

--- wibox.layout.flex: every child grows along the direction, with
-- `max_widget_size` as the ceiling, and across. Clay grows the smallest
-- children first until they are all equal and then all together
-- (clay.h:2357-2391), so children of one size share the space evenly; the
-- engine gives every child the same share whatever its content, so a child
-- whose converted content is wider than its share keeps that width here and
-- takes it from the others.
local function describe_flex(w)
    local node, along = describe_linear(w, flex_class)

    if not node then
        return nil
    end

    local p = w._private

    for i, child in ipairs(p.widgets) do
        node.specs[i] = { widget = child, w = "grow", h = "grow",
            [along .. "max"] = p.max_widget_size }
    end
    return node
end

--- wibox.layout.align -> three children along the direction, sized as the
-- `expand` mode says: fit for the slots the engine asked `:fit`, grow for
-- the ones it gave what was left. Empty elements stand in where the engine
-- leaves space: a grow spacer where a missing second widget would have
-- been, and in "none" mode a grow wrapper around each outer widget, aligned
-- to its edge, so the second centers in the whole width as the engine
-- centers it.
--
-- A slot that grows starts at the size of what it holds and is only ever
-- given more (clay.h:1815-1827 sums a child's content, 2357-2391 grows),
-- and the compress pass will not take it below that content
-- (clay.h:2334-2338). So a grown slot whose own subtree converted keeps a
-- content width larger than the share the engine would have given it, and
-- takes that width from the slots beside it.
local function describe_align(w)
    local p = w._private

    if w.layout ~= align_class.layout then
        return nil
    end

    local along, across = "w", "h"

    if p.dir == "y" then
        along, across = "h", "w"
    end

    local function slot(widget, sizing)
        return { widget = widget, [along] = sizing, [across] = "grow" }
    end

    local specs = {}
    local node = { dir = p.dir, specs = specs }

    -- "outside" with no second widget gives both outer widgets the whole
    -- length, one over the other, which two elements in a row cannot say.
    if p.expand == "outside" and not p.second then
        if p.first or p.third then
            return nil
        end
        return node
    end

    if p.expand == "inside" or not p.second then
        -- The outer widgets at their fit; the second grows between. With
        -- no second widget the third still sits at the far edge.
        if p.first then
            specs[#specs + 1] = slot(p.first, "fit")
        end
        if p.second then
            specs[#specs + 1] = slot(p.second, "grow")
        elseif p.third then
            specs[#specs + 1] = { [along] = "grow" }
        end
        if p.third then
            specs[#specs + 1] = slot(p.third, "fit")
        end
        return node
    end

    if p.expand == "outside" then
        -- The second at its fit; the outer widgets take what it leaves,
        -- splitting it evenly unless one of them holds converted content
        -- wider than its half. A missing one leaves its half empty.
        specs[1] = p.first and slot(p.first, "grow") or { [along] = "grow" }
        specs[2] = slot(p.second, "fit")
        specs[3] = p.third and slot(p.third, "grow") or { [along] = "grow" }
        return node
    end

    -- "none": the second at its fit, the outer widgets at theirs, each
    -- pinned to its edge of a half that grows.
    specs[1] = { [along] = "grow", [across] = "grow",
        align = { x = "left", y = "top" },
        children = { p.first and slot(p.first, "fit") } }
    specs[2] = slot(p.second, "fit")
    specs[3] = { [along] = "grow", [across] = "grow",
        align = p.dir == "y" and { x = "left", y = "bottom" }
            or { x = "right", y = "top" },
        children = { p.third and slot(p.third, "fit") } }
    return node
end

--- wibox.layout.stack -> one floating element per child, attached to the
-- stack's top left and sized to it (clay.h:2230-2234 sizes a floating root
-- with grow sizing to its parent), each drawn over the one before (equal
-- zIndex, declaration order, clay.h:2603-2615). The stack's spacing and the
-- accumulated offsets are that element's padding around the child, which is
-- how the engine shrinks each child: by twice the spacing and by the offset
-- times the child count. A negative offset would need negative padding, so
-- it keeps the stack drawing itself.
local function describe_stack(w)
    local p = w._private
    local spacing, ho, vo = p.spacing or 0, p.h_offset or 0, p.v_offset or 0

    if w.layout ~= stack_class.layout
            or not whole(spacing) or not whole(ho) or not whole(vo) then
        return nil
    end

    local n = #p.widgets
    local specs = {}

    for i, child in ipairs(p.widgets) do
        local k = i - 1

        specs[i] = {
            float = true, w = "grow", h = "grow",
            pad = { spacing + k * ho, spacing + (n - k) * ho,
                spacing + k * vo, spacing + (n - k) * vo },
            children = whole_box(child),
        }
        if p.top_only then
            break
        end
    end

    return { specs = specs }
end

--- wibox.container.place -> child alignment, with the child at its content
-- size on each axis unless `content_fill_*` makes it grow there. The place
-- itself fills the axes `fill_*` names, which is what its own `:fit`
-- answered.
--- wibox.container.constraint -> the child's whole box under a
-- Clay_SizingMinMax on each axis it limits: `max` caps the fit
-- (CLAY_SIZING_FIT(0, limit)), `min` floors it, and `exact` is
-- CLAY_SIZING_FIXED.
local function describe_constraint(w)
    local p = w._private
    local strategy = p.strategy_name

    if w.layout ~= constraint_class.layout then
        return nil
    end

    local node = { specs = whole_box(p.widget) }

    for axis, limit in pairs({ w = p.width, h = p.height }) do
        if strategy == "exact" then
            node[axis] = limit
        elseif strategy == "min" then
            node[axis .. "min"] = limit
        elseif strategy == "max" then
            node[axis .. "max"] = limit
        else
            return nil
        end
    end
    return node
end

local function describe_place(w)
    local p = w._private

    if w.layout ~= place_class.layout then
        return nil
    end

    local node = { specs = {},
        align = { x = p.halign or "center", y = p.valign or "center" },
        w = p.fill_horizontal and "grow" or nil,
        h = p.fill_vertical and "grow" or nil }

    if p.widget then
        node.specs[1] = { widget = p.widget,
            w = p.content_fill_horizontal and "grow" or "fit",
            h = p.content_fill_vertical and "grow" or "fit" }
    end
    return node
end

--- The color a Pango foreground attribute names, straight alpha 0-1.
local function attr_rgba(attr)
    local c = lgi_core.record.cast(attr, Pango.AttrColor).color

    return { c.red / 65535, c.green / 65535, c.blue / 65535, 1 }
end

local function same_rgba(a, b)
    if not a or not b then
        return a == b
    end
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

--- Pango attributes a Clay text element has no field for.
local unsupported_attrs = {
    "UNDERLINE", "STRIKETHROUGH", "RISE", "SHAPE", "SCALE", "LETTER_SPACING",
    "BACKGROUND", "FOREGROUND_ALPHA", "BACKGROUND_ALPHA", "LINE_HEIGHT",
}

--- The one run a textbox's layout amounts to: its text, the font in force
-- and the color its markup set, or nil when the markup says more than one
-- Clay text element can (two fonts, two colors, an underline). Pango's own
-- attribute iterator answers, so a `<span font_desc color>` around escaped
-- text, which is what the taglist and tasklist labels are, is one run.
local function text_run(layout)
    local text = layout.text or ""
    local desc = layout:get_font_description()
    local attrs = layout.attributes

    desc = desc and desc:copy() or Pango.FontDescription.new()
    if not attrs then
        return text, desc, nil
    end

    local it = attrs:get_iterator()
    local run_desc, run_color, first

    first = true
    repeat
        local start = it:range()

        if start < #text then
            for _, name in ipairs(unsupported_attrs) do
                if Pango.AttrType[name] and it:get(Pango.AttrType[name]) then
                    return nil
                end
            end

            local d = desc:copy()
            local fg = it:get(Pango.AttrType.FOREGROUND)
            local color = fg and attr_rgba(fg) or nil

            it:get_font(d, nil, nil)
            if first then
                run_desc, run_color, first = d, color, false
            elseif d:to_string() ~= run_desc:to_string()
                    or not same_rgba(color, run_color) then
                return nil
            end
        end
    until not it:next()
    return text, run_desc or desc, run_color
end

--- wibox.widget.textbox -> an element aligning one CLAY_TEXT child, which
-- is what Clay's own examples make of a label: `CLAY({ .layout = {
-- .childAlignment } }) { CLAY_TEXT(text, CLAY_TEXT_CONFIG({ .fontId,
-- .textColor, .wrapMode, .textAlignment })) }`. The face is interned with
-- an absolute size at the context's dpi (render_text.h), since Clay's
-- fontSize is a whole number. Clay wraps by words and never by character,
-- and the renderer ellipsizes a line at its clip. What a text config has no
-- field for (justify, indent, line spacing, a start or middle ellipsis, a
-- draw override) keeps the textbox drawing itself.
local function describe_textbox(w, fg, st)
    local p = w._private
    local layout = p.layout

    if w.draw ~= textbox_class.draw then
        return nil
    end
    -- Empty text draws nothing whatever the layout says (a prompt's textbox
    -- ellipsizes at the start), and keeps its line's height, as
    -- `textbox:fit` answers it.
    if (layout.text or "") == "" then
        local _, h = w:fit(st.context, st.width, st.height)

        return { hmin = math.ceil(h) }
    end
    if layout:get_justify() or layout:get_indent() ~= 0
            or layout:get_line_spacing() ~= 0 then
        return nil
    end

    local ellipsize = layout:get_ellipsize()

    if ellipsize ~= "NONE" and ellipsize ~= "END" then
        return nil
    end

    local text, desc, color = text_run(layout)

    if not text then
        return nil
    end
    color = color or solid_rgba(fg)
    if not color then
        return nil
    end

    local size = desc:get_size() / Pango.SCALE

    if size <= 0 then
        return nil
    end
    if not desc:get_size_is_absolute() then
        size = size * st.context.dpi / 72
    end
    desc:set_absolute_size(size * Pango.SCALE)

    local font = capi.awesome._clay_font(desc:to_string())

    if not font then
        return nil
    end

    local halign = ({ LEFT = "left", CENTER = "center", RIGHT = "right" })
        [layout:get_alignment()] or "left"
    local node = { specs = {},
        align = { x = halign, y = p.valign or "center" } }

    if text ~= "" then
        node.specs[1] = { text = text, font = font, color = color,
            wrap = "words", halign = halign, ellipsize = ellipsize == "END",
            class = "text" }
    end
    return node
end

--- wibox.widget.imagebox -> an element aligning one image leaf, declared as
-- Clay's own examples declare an image: `.image = { .imageData }` with an
-- `.aspectRatio`, its height growing into the slot and its width following
-- (clay.h recomputes an aspect element's width from its final height). The
-- leaf's pixels are the widget's own surface, which the renderer references
-- and scales into the box. What the renderer does not draw (an SVG handle
-- rendered at the dpi, a `clip_shape`, a fit policy other than the aspect
-- fit, `upscale` or `downscale` off, a scaling cap, a draw override) keeps
-- the imagebox drawing itself.
local function describe_imagebox(w, _, st)
    local p = w._private

    if w.draw ~= imagebox_class.draw then
        return nil
    end
    -- No image: nothing to draw, and no size, as `imagebox:fit` answers.
    if not p.image and not p.handle then
        return {}
    end
    if not p.default or not p.image
            or p.handle or p.clip_shape or p.max_scaling_factor
            or (p.horizontal_fit_policy or "auto") ~= "auto"
            or (p.vertical_fit_policy or "auto") ~= "auto"
            or p.upscale == false or p.downscale == false then
        return nil
    end

    -- The image's size within the drawin, as the engine asked it; an axis
    -- it takes whole grows, and the aspect ratio keeps the other with it.
    local image = { image = p.image._native, class = "image",
        aspect = p.default.width / p.default.height }

    clay.size_leaf(image, w, st.context, st.width, st.height)
    return { specs = { image },
        align = { x = p.halign or "left", y = p.valign or "top" } }
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

--- Per-widget describers, for a widget built with overrides of its own
-- rather than as a class (wibox.widget.systray): the widget's module says
-- what its overrides mean. Weak, so a widget goes with its describer.
local instance_describers = setmetatable({}, { __mode = "k" })
local instance_names = setmetatable({}, { __mode = "k" })

--- Register the describer for one widget.
-- @tparam wibox.widget w The widget.
-- @tparam function describer The describer, as the class table's entries.
-- @tparam string name The widget's class, for the `somewm-client clay
--  tree` dump, where `widget_name` names the class it was built from.
-- @staticfct wibox.clay.describe_widget
function clay.describe_widget(w, describer, name)
    instance_describers[w] = describer
    instance_names[w] = name
end

--- The classes the tree knows, by the `:fit` they share with every instance.
-- A subclass that overrides `:fit` is not in here, and one that overrides
-- `:layout` or a draw callback fails its class's own identity check, which
-- is why no describer checks `:fit` itself.
local classes = {
    [margin_class.fit] = describe_margin,
    [background_class.fit] = describe_background,
    [fixed_class.fit] = describe_fixed,
    [flex_class.fit] = describe_flex,
    [align_class.fit] = describe_align,
    [stack_class.fit] = describe_stack,
    [place_class.fit] = describe_place,
    [constraint_class.fit] = describe_constraint,
    [textbox_class.fit] = describe_textbox,
    [imagebox_class.fit] = describe_imagebox,
}

--- The node a widget compiles to, plus any foreground it puts in force, or
-- nil for a widget that keeps drawing itself. `node.specs` is how the widget
-- sizes its children. A forced size is the widget's own `:fit` answer,
-- whatever its class would have said.
local function describe(w, fg, st)
    local describe_class = instance_describers[w] or classes[w.fit]

    if not describe_class or not common_convertible(w) then
        return nil
    end

    local node, node_fg = describe_class(w, fg, st)

    if node then
        node.w = w._private.forced_width or node.w
        node.h = w._private.forced_height or node.h
    end
    return node, node_fg
end

--- Classes whose instances do not carry their own name.
--
-- `wibox.layout.stack` and `wibox.layout.flex` are both built by calling
-- `wibox.layout.fixed.horizontal`, so `widget_name` is set from fixed's
-- source path and all three report the same name. Each defines its own
-- `:fit`, which is what tells them apart here and in the `classes` table
-- below.
local named_classes = {
    [stack_class.fit] = "wibox.layout.stack",
    [flex_class.fit] = "wibox.layout.flex",
}

--- The widget's class, for the `somewm-client clay tree` dump.
--
-- `gears.object.modulename` derives `widget_name` from the source path and
-- only trims it at a `lib/` directory; somewm installs its library under
-- `lua/`, so the name arrives with the path still in front of it.
local function class_name(w)
    local name = instance_names[w] or named_classes[w.fit] or w.widget_name

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
    classes[class.fit] = function(w)
        if w.layout ~= class.layout then
            return nil
        end
        return { specs = whole_box(w._private[field]) }
    end
end

--- Add a widget class with its describer, for a class defined outside
-- wibox that draws itself in a way the tree can say (awful.widget's
-- systray_icon). An instance overriding `:draw` fails the class's identity
-- check and keeps drawing itself.
-- @tparam table class The widget class, with `fit` and `draw`.
-- @tparam function describer The describer, as the class table's entries.
-- @staticfct wibox.clay.describe_class
function clay.describe_class(class, describer)
    classes[class.fit] = function(w, fg, st)
        if w.draw ~= class.draw then
            return nil
        end
        return describer(w, fg, st)
    end
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
            or not (instance_describers[root] or classes[root.fit]) then
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

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
