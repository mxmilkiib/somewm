---------------------------------------------------------------------------
-- Tests for wibox.clay, the widget-tree-to-Clay compile step.
---------------------------------------------------------------------------

local gcolor = require("gears.color")
local gshape = require("gears.shape")
local background = require("wibox.container.background")
local margin = require("wibox.container.margin")
local rotate = require("wibox.container.rotate")
local fixed = require("wibox.layout.fixed")
local base = require("wibox.widget.base")
local gdebug = require("gears.debug")
local wclay = require("wibox.clay")

local BG = gcolor("#102030")
local BG_RGBA = { 0x10/255, 0x20/255, 0x30/255, 1 }
local context = { dpi = 96 }

-- A described color leaf with a preferred size.
local function leaf_widget(width, height)
    local w = base.make_widget()
    w._clay = { name = "leaf", describe = function(_, fg)
        return { w = width or 10, h = height or 10, bg = wclay.solid_rgba(fg) }
    end }
    return w
end

-- compile() walks the widget tree, in a 100x100 drawable: no hierarchy, no
-- drawable, no drawin, no screen.
local function compile(bg, root, fg)
    local drawable = {
        background_color = bg,
        foreground_color = fg,
        background_image = nil,
    }

    return wclay.compile(drawable, root, context, 100, 100)
end

-- The child node under a margin, or nil when the child is refused.
local function layout_node(w)
    local tree = compile(BG, margin(w, 1, 1, 1, 1), BG)

    return tree.children[1].children[1]
end

-- The node for a widget put in a fixed layout, which asks it for its size
-- along the direction rather than handing it a box.
local function fixed_node(w)
    return layout_node(fixed.horizontal(w)).children[1]
end

local function degraded(w)
    return layout_node(w) == nil
end

-- The tree's nodes, outermost first, following the only child down: what
-- the stage 5 chain was, for trees that are still one.
local function chain(tree)
    local nodes = {}

    while tree do
        nodes[#nodes + 1] = tree
        tree = tree.children and tree.children[1]
    end
    return nodes
end

describe("wibox.clay", function()
    it("offers flex children equal shares less the gaps", function()
        local cairo = require("lgi").cairo
        local imagebox = require("wibox.widget.imagebox")
        local flex = require("wibox.layout.flex")
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 10, 10)
        local layout = flex.vertical(imagebox(surface), imagebox(surface))

        for _, spacing in ipairs { 0, 10 } do
            layout.spacing = spacing
            local tree = compile(BG, layout, BG)
            local children = tree.children[1].children
            assert.is_equal(2, #children)
            for _, child in ipairs(children) do
                local image = child.children[1]
                assert.is_equal(50 - spacing / 2, image.w)
                assert.is_equal(50 - spacing / 2, image.h)
            end
        end
    end)

    it("records both lines when a shape strokes between them", function()
        local ops = wclay.shape_ops(function(cr)
            cr:move_to(1, 2)
            cr:line_to(3, 4)
            cr:stroke()
            cr:move_to(5, 6)
            cr:line_to(7, 8)
        end, 10, 10)

        assert.is_same({ 0, 1, 2, 1, 3, 4, 0, 5, 6, 1, 7, 8 }, ops)
    end)

    it("keeps a transparent background or a gradient shape", function()
        local tree = compile(nil, margin(leaf_widget(), 1, 1, 1, 1), BG)
        assert.is_nil(tree.bg)
        assert.is_equal(1, #tree.children)
        tree = compile(gcolor("linear:0,0:10,0:0,#000000:1,#ffffff"),
            margin(leaf_widget(), 1, 1, 1, 1), BG)
        assert.is_nil(tree.bg)
        assert.is_function(tree.children[1].shape)
        assert.is_equal(2, #tree.children[1].fill.stops)
    end)

    it("converts a drawable whose own background is transparent", function()
        -- The root draws nothing and still takes input over its box, as a
        -- wibox does (an awful.tooltip is one of these).
        local tree = compile(gcolor("#00000000"),
            margin(leaf_widget(), 1, 1, 1, 1), BG)

        assert.is_equal(0, tree.bg[4])
        assert.is_equal(2, #chain(tree) - 1)
    end)

    it("wraps the widget in a surface background image", function()
        local cairo = require("lgi").cairo
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
        local tree, leaves = wclay.compile({
            background_color = BG, foreground_color = BG, background_image = surface,
        }, margin(leaf_widget(), 1, 1, 1, 1), context, 100, 100)
        assert.is_equal(surface._native, tree.children[1].image)
        assert.is_equal(1, #tree.children[1].children)
        assert.is_equal(1, #leaves)
    end)

    it("keeps the drawable background when the root is absent or refused", function()
        assert.is_same({}, compile(BG, base.make_widget(), BG).children)
        assert.is_same({}, compile(BG, nil, BG).children)
    end)

    it("maps margins onto padding, the child growing into them", function()
        local w = leaf_widget()
        local tree, leaves = compile(BG, margin(w, 1, 2, 3, 4), BG)
        local nodes = chain(tree)

        assert.is_equal(3, #nodes)
        assert.is_same(BG_RGBA, nodes[1].bg)
        assert.is_same({ 1, 2, 3, 4 }, nodes[2].pad)
        assert.is_nil(nodes[2].border)
        -- The drawable's widget takes at least the whole drawin and floats
        -- off the root, so an overflowing tree is cut and never squeezed;
        -- the margin's child takes the whole padded box, with its own size
        -- as the floor a parent that wraps its content counts.
        assert.is_true(nodes[2].float)
        assert.is_equal("fit", nodes[2].w)
        assert.is_equal("fit", nodes[2].h)
        assert.is_equal(100, nodes[2].wmin)
        assert.is_equal(100, nodes[2].hmin)
        assert.is_equal("leaf", nodes[3].class)
        assert.is_equal("grow", nodes[3].w)
        assert.is_equal(10, nodes[3].wmin)
        assert.is_equal(10, nodes[3].hmin)
        assert.is_equal(0, #leaves)
    end)

    it("maps a margin color onto a border of the same widths", function()
        local nodes = chain(compile(BG,
            margin(leaf_widget(), 1, 2, 3, 4, "#ff0000"), BG))

        assert.is_same({ 1, 2, 3, 4 }, nodes[2].pad)
        assert.is_same({ 1, 2, 3, 4 }, nodes[2].bw)
        assert.is_same({ 1, 0, 0, 1 }, nodes[2].border)
    end)

    it("maps a background color and a square border", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"

        local nodes = chain(compile(BG, w, BG))

        assert.is_same({ 0, 1, 0, 1 }, nodes[2].bg)
        assert.is_same({ 0, 0, 1, 1 }, nodes[2].border)
        assert.is_same({ 2, 2, 2, 2 }, nodes[2].bw)
        assert.is_equal(0, nodes[2].radius)
        assert.is_nil(nodes[2].pad)
    end)

    it("pads a background whose border strategy shrinks its child", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"
        w.border_strategy = "inner"

        local nodes = chain(compile(BG, w, BG))

        assert.is_same({ 2, 2, 2, 2 }, nodes[2].pad)
    end)

    it("maps a rounded rectangle onto a corner radius", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local nodes = chain(compile(BG, w, BG))

        assert.is_equal(8, nodes[2].radius)
        assert.is_equal("leaf", nodes[3].class)
        assert.is_nil(nodes[3].radius)
    end)

    it("reads the radius a shape function draws", function()
        local nodes = chain(compile(BG,
            background(leaf_widget(), "#00ff00", function(cr, cw, ch)
                return gshape.rounded_rect(cr, cw, ch, 6)
            end), BG))

        assert.is_equal(6, nodes[2].radius)
        -- A function whose radius follows the size draws itself.
        assert.is_same({}, compile(BG,
            background(leaf_widget(), "#00ff00", gshape.rounded_bar), BG).children)
    end)

    it("converts a rounded background under a margin", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local tree, leaves = compile(BG, margin(w, 5, 5, 5, 5), BG)
        local nodes = chain(tree)

        assert.is_equal(4, #nodes)
        assert.is_same({ 5, 5, 5, 5 }, nodes[2].pad)
        assert.is_equal(8, nodes[3].radius)
        assert.is_equal("leaf", nodes[4].class)
        assert.is_equal(0, #leaves)
    end)

    it("converts a rounded background over a converting child", function()
        local inner = margin(leaf_widget(), 2, 2, 2, 2)
        local w = background(inner, "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local tree, leaves = compile(BG, w, BG)
        local nodes = chain(tree)

        -- The renderer cuts the margin and its leaf to the arc; the tree
        -- only names the radius.
        assert.is_equal(4, #nodes)
        assert.is_equal(8, nodes[2].radius)
        assert.is_same({ 2, 2, 2, 2 }, nodes[3].pad)
        assert.is_equal("leaf", nodes[4].class)
        assert.is_equal(0, #leaves)
    end)

    it("converts a rounded background with nothing filling it", function()
        local w = background(leaf_widget())

        w:set_shape(gshape.rounded_rect, 8)

        local nodes = chain(compile(BG, w, BG))

        assert.is_equal(8, nodes[2].radius)
        assert.is_nil(nodes[2].bg)
        assert.is_equal("leaf", nodes[3].class)
    end)

    it("refuses a rounded background that also has a border", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)
        w.border_width = 1
        w.border_color = "#0000ff"

        assert.is_same({}, compile(BG, w, BG).children)
    end)

    it("converts containers down to the first it cannot", function()
        local w = leaf_widget()
        local stopper = rotate(margin(w, 2, 2, 2, 2))
        local tree, leaves = compile(BG,
            background(margin(stopper, 4, 4, 4, 4), "#00ff00"), BG)
        local nodes = chain(tree)

        -- The rotate and its subtree are absent beneath the margin.
        assert.is_equal(3, #nodes)
        assert.is_same({ 0, 1, 0, 1 }, nodes[2].bg)
        assert.is_same({ 4, 4, 4, 4 }, nodes[3].pad)
        assert.is_nil(nodes[4])
    end)

    it("carries the innermost background foreground to the leaf", function()
        local w = background(leaf_widget(), "#00ff00")
        w.fg = gcolor("#ff00ff")
        local nodes = chain(compile(BG, w, BG))
        assert.is_same({ 1, 0, 1, 1 }, nodes[3].bg)
    end)

    it("omits invisible widgets and multiplies opacity through children", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)
        w.visible = false
        assert.is_same({}, compile(BG, w, BG).children)
        w.visible, w.opacity = true, 0.5
        local nodes = chain(compile(BG, w, BG))
        assert.is_equal(0.5, nodes[3].bg[4])
    end)

    it("tells Clay a forced size where a parent asks for one", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        w.forced_width = 20

        -- A fixed layout asks its child's size along the direction: the
        -- forced width is that answer. A margin hands its child the whole
        -- box, and counts the forced width as the floor.
        local node = fixed_node(w)

        assert.is_equal(20, node.w)
        assert.is_equal("grow", node.h)
        node = layout_node(w)
        assert.is_equal("grow", node.w)
        assert.is_equal(20, node.wmin)
    end)



    it("stops at a subclass that overrides the layout it converted", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        rawset(w, "layout", function() return {} end)
        assert.is_same({}, compile(BG, w, BG).children)
    end)

    it("stops at a margin that shrinks away with its child", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        w.draw_empty = false
        assert.is_same({}, compile(BG, w, BG).children)
    end)
end)

describe("wibox.clay fixed", function()
    it("maps direction and spacing, children at their size along it, whole across", function()
        local l = fixed.horizontal(leaf_widget(10, 5),
            margin(leaf_widget(20, 5), 1, 1, 1, 1))

        l.spacing = 4

        local node = layout_node(l)

        assert.is_equal("x", node.dir)
        assert.is_equal(4, node.gap)
        assert.is_equal(2, #node.children)
        assert.is_equal("leaf", node.children[1].class)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal("grow", node.children[1].h)
        assert.is_equal(5, node.children[1].hmin)
        -- A converted child wraps its content, which is Clay's default.
        assert.is_nil(node.children[2].w)
        assert.is_equal("grow", node.children[2].h)

        local v = layout_node(fixed.vertical(leaf_widget(5, 10)))

        assert.is_equal("y", v.dir)
        assert.is_equal(10, v.children[1].h)
        assert.is_equal("grow", v.children[1].w)
    end)

    it("grows the last child when fill_space is set", function()
        local l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(20, 5))

        l:fill_space(true)

        local node = layout_node(l)

        assert.is_equal(10, node.children[1].w)
        assert.is_equal("grow", node.children[2].w)
        assert.is_equal(20, node.children[2].wmin)
    end)

    it("omits invisible children", function()
        local hidden = leaf_widget(10, 5)

        hidden._private.visible = false

        local l = fixed.horizontal(leaf_widget(10, 5), hidden,
            leaf_widget(0, 5), leaf_widget(20, 5))
        local node = layout_node(l)

        assert.is_equal(3, #node.children)
        assert.is_equal(0, node.children[2].w)
        assert.is_equal(20, node.children[3].w)
    end)

    it("is refused for a spacing widget, negative spacing and overrides", function()
        local l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))

        l.spacing = 3
        l.spacing_widget = leaf_widget(3, 5)
        assert.is_true(degraded(l))

        l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = -2
        assert.is_true(degraded(l))

        l = fixed.horizontal(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return fixed.layout(self, ...) end)
        assert.is_true(degraded(l))

        l = fixed.horizontal(leaf_widget(10, 5))
        l._clay = { name = "cutoff_override", describe = fixed._clay.describe }
        rawset(l, "fit", function() return 0, 0 end)
        local warning = stub(gdebug, "print_warning")
        assert.is_true(degraded(l))
        assert.is_true(degraded(l))
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay flex", function()
    local flex = require("wibox.layout.flex")

    it("grows every child along the direction, with max_widget_size as the ceiling", function()
        local l = flex.horizontal(leaf_widget(10, 5), leaf_widget(50, 5))

        l.spacing = 2

        local node = layout_node(l)

        assert.is_equal("x", node.dir)
        assert.is_equal(2, node.gap)
        assert.is_equal(2, #node.children)
        assert.is_equal("grow", node.children[1].w)
        assert.is_equal("grow", node.children[1].h)
        assert.is_nil(node.children[1].wmax)
        assert.is_equal("leaf", node.children[2].class)

        l.max_widget_size = 30
        node = layout_node(l)
        assert.is_equal(30, node.children[1].wmax)
        assert.is_equal(30, node.children[2].wmax)
        assert.is_nil(node.children[2].hmax)

        local v = flex.vertical(leaf_widget(5, 10))

        v.max_widget_size = 12
        node = layout_node(v)
        assert.is_equal("y", node.dir)
        assert.is_equal(12, node.children[1].hmax)
    end)

    it("is refused for a spacing widget, negative spacing and overrides", function()
        local l = flex.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))

        l.spacing = 3
        l.spacing_widget = leaf_widget(3, 5)
        assert.is_true(degraded(l))

        l = flex.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = -2
        assert.is_true(degraded(l))

        l = flex.horizontal(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return flex.layout(self, ...) end)
        assert.is_true(degraded(l))
    end)
end)

describe("wibox.clay align", function()
    local align = require("wibox.layout.align")

    local function stub(w)
        return leaf_widget(w, 5)
    end

    it("inside: outer widgets at their size, the second grows between", function()
        local node = layout_node(align.horizontal(stub(10), stub(200), stub(20)))

        assert.is_equal("x", node.dir)
        assert.is_equal(3, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal("grow", node.children[2].w)
        assert.is_equal(20, node.children[3].w)
        for _, child in ipairs(node.children) do
            assert.is_equal("leaf", child.class)
            assert.is_equal("grow", child.h)
        end

        local v = layout_node(align.vertical(leaf_widget(5, 10), stub(5), nil))

        assert.is_equal("y", v.dir)
        assert.is_equal(10, v.children[1].h)
        assert.is_equal("grow", v.children[1].w)
    end)

    it("inside: with no second widget a grow spacer keeps the third at the far edge", function()
        local node = layout_node(align.horizontal(stub(60), nil, stub(60)))

        assert.is_equal(3, #node.children)
        assert.is_equal(60, node.children[1].w)
        assert.is_true(node.children[2].spacer)
        assert.is_equal("grow", node.children[2].w)
        assert.is_equal(60, node.children[3].w)
    end)

    it("outside: the second at its size, the outer widgets grow", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        l.expand = "outside"

        local node = layout_node(l)

        assert.is_equal(3, #node.children)
        assert.is_equal("grow", node.children[1].w)
        assert.is_equal(10, node.children[1].wmin)
        assert.is_equal(20, node.children[2].w)
        assert.is_equal("grow", node.children[3].w)

        -- A missing outer widget leaves its half empty.
        l = align.horizontal(nil, stub(20), stub(30))
        l.expand = "outside"
        node = layout_node(l)
        assert.is_true(node.children[1].spacer)
        assert.is_equal("grow", node.children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_equal("leaf", node.children[3].class)
    end)

    it("outside without a second widget is refused", function()
        local l = align.horizontal(stub(10), nil, stub(30))

        l.expand = "outside"
        assert.is_nil(layout_node(l))

        l = align.horizontal(nil, nil, nil)
        l.expand = "outside"
        assert.is_equal(0, #layout_node(l).children)
    end)

    it("none: the second centers in the whole, the outer widgets pinned to their edges", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        l.expand = "none"

        local node = layout_node(l)

        assert.is_equal(3, #node.children)
        -- Two grow wrappers around the second, each holding one outer widget.
        assert.is_true(node.children[1].spacer)
        assert.is_equal("grow", node.children[1].w)
        assert.is_same({ x = "left", y = "top" }, node.children[1].align)
        assert.is_equal(10, node.children[1].children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_same({ x = "right", y = "top" }, node.children[3].align)
        assert.is_equal(30, node.children[3].children[1].w)

        -- A missing outer widget leaves its wrapper empty.
        l = align.horizontal(nil, stub(20), stub(30))
        l.expand = "none"
        node = layout_node(l)
        assert.is_equal(0, #node.children[1].children)

        l = align.vertical(leaf_widget(5, 10), leaf_widget(5, 20), nil)
        l.expand = "none"
        node = layout_node(l)
        assert.is_same({ x = "left", y = "bottom" }, node.children[3].align)
        assert.is_equal(10, node.children[1].children[1].h)
    end)

    it("is refused for an override", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        rawset(l, "layout", function(self, ...) return align.layout(self, ...) end)
        assert.is_nil(layout_node(l))
    end)
end)

describe("wibox.clay stack", function()
    local stack = require("wibox.layout.stack")

    it("floats each child over the one before, sized to the stack", function()
        local a, b = leaf_widget(10, 5), leaf_widget(20, 5)
        local node = layout_node(stack(a, b))

        assert.is_equal(2, #node.children)
        for _, wrapper in ipairs(node.children) do
            assert.is_true(wrapper.float)
            assert.is_same({ 0, 0, 0, 0 }, wrapper.pad)
            assert.is_true(wrapper.spacer)
            assert.is_equal("grow", wrapper.w)
            assert.is_equal(1, #wrapper.children)
            assert.is_equal("leaf", wrapper.children[1].class)
            assert.is_equal("grow", wrapper.children[1].w)
        end

        local _, leaves = compile(BG, margin(stack(a, b), 1, 1, 1, 1), BG)

        assert.is_equal(0, #leaves)
    end)

    it("turns spacing and offsets into padding around each child", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        l.spacing = 3
        l.horizontal_offset = 4
        l.vertical_offset = 1

        local node = layout_node(l)

        assert.is_same({ 3, 3 + 2 * 4, 3, 3 + 2 * 1 }, node.children[1].pad)
        assert.is_same({ 3 + 4, 3 + 4, 3 + 1, 3 + 1 }, node.children[2].pad)
    end)

    it("declares only the first child with top_only", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        l.top_only = true

        local node = layout_node(l)

        assert.is_equal(1, #node.children)
    end)

    it("is refused for a negative offset and an override", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        l.horizontal_offset = -2
        assert.is_nil(layout_node(l))

        l = stack(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return stack.layout(self, ...) end)
        assert.is_nil(layout_node(l))
    end)
end)

describe("wibox.clay place", function()
    local place = require("wibox.container.place")

    it("aligns a child at its size on both axes", function()
        local node = layout_node(place(leaf_widget(10, 20)))

        assert.is_same({ x = "center", y = "center" }, node.align)
        assert.is_equal(1, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal(20, node.children[1].h)

        node = layout_node(place(leaf_widget(10, 20), "right", "bottom"))
        assert.is_same({ x = "right", y = "bottom" }, node.align)
    end)

    it("grows the child on an axis content_fill_* names", function()
        local c = place(leaf_widget(10, 20))

        c.content_fill_horizontal = true

        local node = layout_node(c)

        assert.is_equal("grow", node.children[1].w)
        assert.is_equal(20, node.children[1].h)

        c.content_fill_vertical = true
        node = layout_node(c)
        assert.is_equal("grow", node.children[1].h)
    end)

    it("fills the axes fill_* names, where a parent asks its size", function()
        local c = place(leaf_widget(10, 20))

        assert.is_nil(fixed_node(c).w)
        c.fill_horizontal = true
        assert.is_equal("grow", fixed_node(c).w)
    end)

    it("converts with no child, and is refused for an override", function()
        assert.is_equal(0, #layout_node(place()).children)

        local c = place(leaf_widget(10, 20))

        rawset(c, "layout", function(self, ...) return place.layout(self, ...) end)
        assert.is_nil(layout_node(c))
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
