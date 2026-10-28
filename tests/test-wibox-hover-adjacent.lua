-- The tag pager's real shape and hover model: imagebox cells that
-- re-render their surface inside mouse::enter/leave, with one shared
-- hover_tag global like plugins/tag_pager.lua. Entering a cell must
-- emit mouse::leave on the previous one; on an empty screen the wash
-- used to stick while crossing cells.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local cairo = require('lgi').cairo
local s = screen[1]

local CELL_W, CELL_H = 40, 24

local hover_cell
local function render(hovered)
    local surface = cairo.ImageSurface.create(cairo.Format.ARGB32, CELL_W, CELL_H)
    local cr = cairo.Context(surface)
    cr:set_source_rgb(1, hovered and 1 or 0, 0)
    cr:paint()
    return surface
end

local enters, leaves = { a = 0, b = 0 }, { a = 0, b = 0 }
local order = {}
local function cell(key)
    local img = wibox.widget.imagebox()
    img.resize = true
    img.forced_width = CELL_W
    img.forced_height = CELL_H
    img:set_image(render(false))
    img:connect_signal('mouse::enter', function()
        enters[key] = enters[key] + 1
        order[#order + 1] = 'enter ' .. key
        hover_cell = key
        img:set_image(render(true))
    end)
    img:connect_signal('mouse::leave', function()
        leaves[key] = leaves[key] + 1
        order[#order + 1] = 'leave ' .. key
        if hover_cell == key then
            hover_cell = nil
            img:set_image(render(false))
        end
    end)
    return img
end

local a, b = cell('a'), cell('b')

local function cell_hit(host, x, y)
    for _, hit in ipairs(host:find_widgets(x, y)) do
        if hit.widget == a or hit.widget == b then return hit.widget end
    end
end

runner.run_async(function()
    local row = wibox.layout.fixed.horizontal()
    row.spacing = 0
    row:add(a)
    row:add(b)

    local pager = wibox.container.background(
        wibox.container.margin(
            wibox.widget { row, valign = 'center', widget = wibox.container.place },
            1, 0, 0, 0),
        '#000000')

    local bar = awful.wibar { position = 'top', screen = s, height = 30 }
    bar:setup {
        layout = wibox.layout.align.horizontal,
        { layout = wibox.layout.fixed.horizontal, pager },
    }

    local bar_geo
    assert(async.wait_for_condition(function()
        bar_geo = bar:geometry()
        return bar_geo and cell_hit(bar, 20, 15) == a
    end, 3, .01), 'the bar never solved its cells')

    -- Park the cursor over cell A, then poke motion so enter lands.
    mouse.coords({ x = bar_geo.x + 20, y = bar_geo.y + 15 }, false)
    mouse._fake_motion(0, 0)
    assert(async.wait_for_condition(function() return enters.a == 1 end, 2, .01),
        'cell A never saw mouse::enter')

    -- Slide horizontally into cell B: A must leave before B enters.
    mouse.coords({ x = bar_geo.x + CELL_W + 20, y = bar_geo.y + 15 }, false)
    mouse._fake_motion(0, 0)
    assert(async.wait_for_condition(function() return enters.b == 1 end, 2, .01),
        'cell B never saw mouse::enter')
    assert(async.wait_for_condition(function() return leaves.a == 1 end, 2, .01),
        string.format('cell A kept its hover after the cursor crossed to B '
            .. '(order: %s)', table.concat(order, ', ')))

    -- The shared edge: Clay's closed-edge containment answers both cells
    -- there; a hit must name only the later one, like render_hit. B is
    -- already hovered, so crossing onto the boundary must not re-enter A.
    local edge
    for _, hit in ipairs(bar:find_widgets(2, 15)) do
        if hit.widget == a then edge = hit.x + hit.width end
    end
    assert(edge, 'cell A lost its solved box')
    mouse.coords({ x = bar_geo.x + edge, y = bar_geo.y + 15 }, false)
    mouse._fake_motion(0, 0)
    async.sleep(0.1)
    assert(enters.a == 1 and leaves.a == 1 and enters.b == 1 and leaves.b == 0,
        string.format('the shared edge re-entered cell A '
            .. '(order: %s)', table.concat(order, ', ')))

    -- And back to cell A: B leaves.
    mouse.coords({ x = bar_geo.x + 20, y = bar_geo.y + 15 }, false)
    mouse._fake_motion(0, 0)
    assert(async.wait_for_condition(function() return leaves.b == 1 end, 2, .01),
        string.format('cell B kept its hover after the cursor crossed back '
            .. '(order: %s)', table.concat(order, ', ')))

    bar.visible = false
    runner.done()
end)
