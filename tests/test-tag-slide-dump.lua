local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump() return awesome._clay_tree(s) end

runner.run_async(function()
    beautiful.animation_tag = {"slide_right", "slide_left"}
    beautiful.animation_tag_duration = .8
    local original = s.selected_tag
    local other = awful.tag.add('slide-pair', {screen = s, layout = awful.layout.suit.tile})
    ruled.client.append_rule { rule = {class = 'SLIDE_A'},
        properties = {border_width = 0, floating = false} }
    ruled.client.append_rule { rule = {class = 'SLIDE_B'},
        properties = {border_width = 0, floating = false, tag = other} }
    s.selected_tag.layout = awful.layout.suit.tile
    local report = os.tmpname()
    awful.spawn{binary, 'SLIDE_A', report, '0', 'ff0000cc', '0'}
    awful.spawn{binary, 'SLIDE_B', report, '0', '00ff00cc', '0'}
    assert(async.wait_for_client('SLIDE_A', 2))
    assert(async.wait_for_client('SLIDE_B', 2))
    async.sleep(.3)
    other:view_only()
    async.sleep(.15)
    io.stderr:write('=== MID-EXIT DUMP ===\n' .. dump() .. '\n=== END DUMP ===\n')
    async.sleep(.7)
    io.stderr:write('[DONE]\n')
    runner.done()
end)
