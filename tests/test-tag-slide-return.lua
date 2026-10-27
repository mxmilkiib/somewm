-- A departing client's ghost borrows the composite leaf's element id for
-- its slide. Returning to its tag inside the slide's duration must drop
-- the ghost: declaring both in one frame is a duplicate element id, which
-- the error handler treats as a fatal invariant violation.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump() return awesome._clay_tree(s) end

local function client_x()
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*CLIENT ') then
            local x = line:match('box (%-?%d+),%-?%d+ %d+x')
            if x then return tonumber(x) end
        end
    end
end

runner.run_async(function()
    beautiful.animation_tag = {"slide_right", "slide_left"}
    beautiful.animation_tag_duration = 1
    local original = s.selected_tag
    local other = awful.tag.add('slide-return', {screen = s, layout = awful.layout.suit.tile})
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

    -- A departs on the forward switch, then returns inside the slide: the
    -- frame declaring A's live surface must not keep the ghost's leaf.
    other:view_only()
    async.sleep(.15)
    original:view_only()
    async.sleep(.15)
    assert(client_x(), 'A lost its frame on the return: ' .. dump())
    async.sleep(1)
    assert(client_x(), 'A never settled: ' .. dump())

    io.stderr:write('[PASS] a returning client drops its tag slide ghost\n')
    runner.done()
end)
