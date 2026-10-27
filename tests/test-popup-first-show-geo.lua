---------------------------------------------------------------------------
-- Reproduction: a hidden awful.popup keeps its construction 1x1 drawin
-- geometry until the first visible frame publishes the content size, so
-- manual placement that reads popup.width/height misfires on first show.
-- The attachment path places it correctly on that same first frame.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local bar, popup, target, hit

runner.run_steps {
    function()
        bar = awful.wibar { screen = s, position = 'top', height = 28,
            widget = wibox.widget.textbox('x') }
        target = wibox.widget.textbox('clock')
        bar:setup { layout = wibox.layout.align.horizontal, expand = 'none',
            wibox.widget.textbox('menu'), wibox.widget.textbox('mid'), target }
        popup = awful.popup { screen = s, visible = false, ontop = true,
            bg = '#ff0000',
            widget = wibox.widget { wibox.widget.textbox('popup body'),
                forced_width = 200, forced_height = 100,
                widget = wibox.container.background } }
        return true
    end,
    function(n)
        awesome._test_redeclare()
        for _, h in ipairs(bar:find_widgets(s.geometry.width - 3, 14)) do
            if h.widget == target then hit = h end
        end
        if not hit then assert(n < 10, 'no hit on the target widget') return end
        -- what popup_common.show_placement sees on the first click
        popup:_apply_size_now(false)
        assert(popup.width <= 1 and popup.height <= 1,
            ('expected the construction 1x1 before first frame, got %dx%d')
                :format(popup.width, popup.height))
        -- the corrected fallback: attachment with the side resolved
        awful.placement.next_to(popup, {
            geometry = hit,
            preferred_positions = 'bottom',
            preferred_anchors = 'back',
            honor_workarea = true,
        })
        popup.visible = true
        return true
    end,
    function(n)
        awesome._test_redeclare()
        local g = popup:geometry()
        if g.width <= 1 then assert(n < 10, 'popup size not published') return end
        -- below the widget, right-aligned: popup top at anchor bottom,
        -- popup right at anchor right (bar has no border, screen at 0,0)
        local ax, ay = hit.x, hit.y
        assert(g.y == ay + hit.height,
            ('popup y %d, want anchor bottom %d'):format(g.y, ay + hit.height))
        assert(g.x + g.width == ax + hit.width,
            ('popup right %d, want anchor right %d'):format(g.x + g.width, ax + hit.width))
        io.stderr:write(('[PASS] popup lands at %d,%d %dx%d on its first frame\n')
            :format(g.x, g.y, g.width, g.height))
        return true
    end,
    function()
        bar.visible = false
        popup.visible = false
        return true
    end,
}
