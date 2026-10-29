---------------------------------------------------------------------------
-- Reproduction: an awful.popup attached to a wibar widget occurrence on a
-- secondary output is never declared and stays parked at 1x1+0+0.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

if not awesome._test_add_output then
    return runner.skip("awesome._test_add_output not available")
end

local initial_count = screen.count()
local left, right, bar, popup, target, hit

local steps = {
    function()
        assert(awesome._test_add_output(800, 600), "_test_add_output failed")
        return true
    end,

    function()
        return screen.count() > initial_count or nil
    end,

    function()
        for s in screen do
            if not left or s.geometry.x < left.geometry.x then left = s end
            if not right or s.geometry.x > right.geometry.x then right = s end
        end
        assert(left ~= right)
        return true
    end,

    -- Bars on both outputs, the anchor widget instance shared between them
    -- and wrapped like the user's centered_bar (place + margin + background).
    function()
        target = wibox.widget.textbox("anchor")
        local function wrap(w)
            return {
                {
                    w,
                    margins = 1,
                    widget = wibox.container.margin,
                },
                bg = "#224466",
                widget = wibox.container.background,
            }
        end
        for _, s in ipairs { left, right } do
            local b = awful.wibar { screen = s, position = "top", height = 26 }
            b:setup {
                layout = wibox.layout.align.horizontal,
                expand = "none",
                wibox.widget.textbox("menu"),
                wibox.widget.textbox("mid"),
                wibox.container.place(wrap(target)),
            }
            if s == right then bar = b end
        end
        popup = awful.popup { screen = right, visible = false, ontop = true,
            bg = "#ff0000",
            widget = wibox.widget { wibox.widget.textbox("popup body"),
                forced_width = 200, forced_height = 100,
                widget = wibox.container.background } }
        return true
    end,

    function(n)
        awesome._test_redeclare()
        for _, h in ipairs(bar:find_widgets(right.geometry.width - 5, 13)) do
            if h.widget == target then hit = h end
        end
        if not hit then assert(n < 10, "no hit on the target widget") return end
        awful.placement.next_to(popup, {
            geometry = hit,
            preferred_positions = "bottom",
            preferred_anchors = "back",
            honor_workarea = true,
        })
        popup.visible = true
        return true
    end,

    function(n)
        awesome._test_redeclare()
        local g = popup:geometry()
        if g.width <= 1 then assert(n < 10, "popup never got a solved size") return end
        io.stderr:write(("[PASS] popup attached at %d,%d %dx%d\n")
            :format(g.x, g.y, g.width, g.height))
        return true
    end,

    -- A hit captured before an async show can name an occurrence the host's
    -- recompile has renumbered. The same identity+host with a stale occurrence
    -- must fall back to the live occurrence, not park the drawin.
    function()
        popup.visible = false
        popup.screen = right
        popup:geometry { width = 1, height = 1 }
        local hits = bar:find_widgets(right.geometry.width - 5, 13)
        local cur
        for _, h in ipairs(hits) do if h.widget == target then cur = h end end
        assert(cur, "no fresh hit")
        popup.drawin.attachment = { kind = 1, parent = 8, own = 6,
            target = require("wibox.clay").identity(target),
            occurrence = cur.occurrence + 9999, -- renumbered away
            host = cur.drawable.drawable }
        popup.visible = true
        return true
    end,

    function(n)
        awesome._test_redeclare()
        local g = popup:geometry()
        if g.width <= 1 then assert(n < 10, "stale occurrence parked the popup") return end
        io.stderr:write(("[PASS] stale occurrence fell back at %d,%d %dx%d\n")
            :format(g.x, g.y, g.width, g.height))
        return true
    end,

    -- An attached drawin's declaring screen is its host's: a popup whose
    -- authored position maps to the left screen still resolves on the right
    -- one when the attachment host is there.
    function()
        popup.visible = false
        popup:geometry { x = left.geometry.x + 10, y = left.geometry.y + 10,
            width = 1, height = 1 }
        local hits = bar:find_widgets(right.geometry.width - 5, 13)
        local cur
        for _, h in ipairs(hits) do if h.widget == target then cur = h end end
        assert(cur, "no fresh hit")
        popup.drawin.attachment = { kind = 1, parent = 8, own = 6,
            target = require("wibox.clay").identity(target),
            occurrence = cur.occurrence,
            host = cur.drawable.drawable }
        popup.visible = true
        return true
    end,

    function(n)
        awesome._test_redeclare()
        local g = popup:geometry()
        if g.width <= 1 or g.x < right.geometry.x then
            assert(n < 10, "stale drawin screen parked the popup") return
        end
        io.stderr:write(("[PASS] wrong-screen popup resolved at %d,%d %dx%d\n")
            :format(g.x, g.y, g.width, g.height))
        return true
    end,

    function()
        bar.visible = false
        popup.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
