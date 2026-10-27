-- The {enter, exit} slide pair pans the client layer on a tag switch, and
-- the direction mirrors on a backward switch: forward (higher index) sends
-- exits left and entrances from the right, backward swaps both.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump()
    return awesome._clay_tree(s)
end

local function client_x()
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*CLIENT ') then
            local x, w = line:match('box (%-?%d+),%-?%d+ (%d+)x')
            if x then return tonumber(x), tonumber(w) end
        end
    end
end

local function exit_clone_x()
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s+%- w=') then
            local x, w = line:match('box (%-?%d+),%-?%d+ (%d+)x')
            if x then return tonumber(x), tonumber(w) end
        end
    end
end

runner.run_async(function()
    beautiful.animation_tag = {"slide_right", "slide_left"}
    beautiful.animation_tag_duration = .5
    local original = s.selected_tag
    local other = awful.tag.add('slide-pair', {screen = s, layout = awful.layout.suit.tile})
    ruled.client.append_rule {
        rule = {class = 'SLIDE_A'},
        properties = {border_width = 0, floating = false},
    }
    ruled.client.append_rule {
        rule = {class = 'SLIDE_B'},
        properties = {border_width = 0, floating = false, tag = other},
    }
    s.selected_tag.layout = awful.layout.suit.tile
    local report = os.tmpname()
    awful.spawn{binary, 'SLIDE_A', report, '0', 'ff0000cc', '0'}
    awful.spawn{binary, 'SLIDE_B', report, '0', '00ff00cc', '0'}
    assert(async.wait_for_client('SLIDE_A', 2))
    assert(async.wait_for_client('SLIDE_B', 2))
    async.sleep(.3)
    local ax = assert(client_x(), 'no client box: ' .. dump())

    -- Forward: A exits left. B's first describe is appear, not tag.
    other:view_only()
    async.sleep(.1)
    local ex, ew = exit_clone_x()
    assert(ex and ex < ax and ex > -ew, 'forward exit did not slide left: ' .. dump())
    async.sleep(.5)
    local bx = assert(client_x(), 'B not on the second tag: ' .. dump())

    -- Backward: B exits right, A enters from the left.
    original:view_only()
    async.sleep(.1)
    ex, ew = exit_clone_x()
    assert(ex and ex > bx and ex < bx + ew, 'backward exit did not slide right: ' .. dump())
    local nx = assert(client_x(), 'no entering client: ' .. dump())
    assert(nx < ax, 'backward entrance did not come from the left: ' .. dump())
    async.sleep(.5)

    -- Forward again: A exits left, B enters from the right.
    other:view_only()
    async.sleep(.1)
    ex, ew = exit_clone_x()
    assert(ex and ex < ax and ex > -ew, 'second forward exit did not slide left: ' .. dump())
    nx = assert(client_x(), 'no entering client: ' .. dump())
    assert(nx > bx, 'forward entrance did not come from the right: ' .. dump())
    async.sleep(.5)
    assert(client_x() == bx, 'client did not settle: ' .. dump())

    io.stderr:write('[PASS] tag slide pair pans both directions by tag delta\n')
    runner.done()
end)
