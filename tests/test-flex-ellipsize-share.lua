---------------------------------------------------------------------------
-- An ellipsizing textbox in a flex row takes its share, not its natural
-- width: the long title shrinks instead of inflating its cell.
--
-- Run: make test-one TEST=tests/test-flex-ellipsize-share.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")

local W = 600
local bar, short, long

local function cells()
    local out = {}
    for x = 0, W - 1, 4 do
        for _, h in ipairs(bar:find_widgets(x, 12)) do
            if h.widget == short or h.widget == long then out[h.widget] = h.width end
        end
    end
    return out[short], out[long]
end

local steps = {
    function(count)
        if count == 1 then
            short = wibox.widget.textbox("short")
            long = wibox.widget.textbox(string.rep("a very long title ", 20))
            short:set_ellipsize("end")
            long:set_ellipsize("end")
            bar = wibox { x = 0, y = 0, width = W, height = 24, screen = screen[1],
                bg = "#101010", fg = "#ffffff", visible = true }
            bar:setup {
                layout = wibox.layout.align.horizontal,
                nil,
                {
                    { layout = wibox.layout.flex.horizontal, short, long },
                    width = 400, strategy = "max", widget = wibox.container.constraint,
                },
                nil,
            }
            return nil
        end
        awesome._test_redeclare()
        local a, b = cells()
        if not (a and b) then assert(count < 20, "no cell boxes") return nil end
        io.stderr:write(awesome._clay_tree(screen[1]), "\n")
        assert(math.abs(a - b) <= 8, ("cells uneven: %s vs %s"):format(a, b))
        io.stderr:write(("[PASS] flex cells %d / %d\n"):format(a, b))
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
