-- A minimized client is not a tag switch: with animation_minimize set its
-- exit slides by that word instead of riding the tag pair. Unset, it keeps
-- riding the tag exit for compatibility.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump() return awesome._clay_tree(s) end

-- The retained exit clone's box, like the tag slide tests read it.
local function exit_clone_box()
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s+%- w=') then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            if x then return tonumber(x), tonumber(y), tonumber(w), tonumber(h) end
        end
    end
end

-- A minimize's slide is the ghost leaf alone, run under the flow so the
-- window tucks under the bar instead of painting chrome over it.
local function ghost_box()
    for line in dump():gmatch('[^\n]+') do
        if line:match('GHOST') then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            local z = line:match('band (%-?%d+)')
            if x then return tonumber(x), tonumber(y), tonumber(w), tonumber(h), tonumber(z) end
        end
    end
end

local function client_box()
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*CLIENT ') then
            local x, y = line:match('box (%-?%d+),(%-?%d+) %d+x%d+')
            if x then return tonumber(x), tonumber(y) end
        end
    end
end

runner.run_async(function()
    beautiful.animation_tag = {"slide_right", "slide_left"}
    beautiful.animation_tag_duration = 1
    beautiful.animation_minimize = "slide_up"
    beautiful.animation_minimize_duration = 1
    ruled.client.append_rule {
        rule = {class = 'MIN_A'},
        properties = {border_width = 0, floating = false},
    }
    s.selected_tag.layout = awful.layout.suit.tile
    local report = os.tmpname()
    awful.spawn{binary, 'MIN_A', report, '0', 'ff0000cc', '0'}
    local c = assert(async.wait_for_client('MIN_A', 2))
    async.sleep(.3)
    local ax, ay = client_box()
    assert(ax, 'no client box: ' .. dump())

    c.minimized = true
    async.sleep(.15)
    local gx, gy, gw, gh, gz = ghost_box()
    assert(gx and gy, 'minimize left no ghost: ' .. dump())
    assert(gy < ay, 'minimize ghost did not slide up (y ' .. gy .. ' not < ' .. ay .. '): ' .. dump())
    assert(math.abs(gx - ax) < 4, 'minimize ghost slid sideways (x ' .. gx .. ' vs ' .. ax .. '): ' .. dump())
    assert(gz and gz < 0, 'minimize ghost not under the flow (band ' .. tostring(gz) .. '): ' .. dump())
    async.sleep(1)

    -- Without animation_minimize a minimize still rides the tag exit: left.
    beautiful.animation_minimize = nil
    awful.spawn{binary, 'MIN_B', report, '0', '00ff00cc', '0'}
    local b = assert(async.wait_for_client('MIN_B', 2))
    async.sleep(.3)
    local bx = client_box()
    assert(bx, 'second client has no box: ' .. dump())
    b.minimized = true
    async.sleep(.15)
    local ex2 = exit_clone_box()
    assert(ex2, 'tag exit left no clone: ' .. dump())
    assert(ex2 < bx, 'unset minimize exit did not ride the tag slide left: ' .. dump())
    async.sleep(1)

    io.stderr:write('[PASS] a minimize exit slides up, not along the tag pan\n')
    runner.done()
end)
