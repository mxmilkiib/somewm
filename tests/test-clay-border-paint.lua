-- A border colour change repaints the border from the stored node: it moves
-- nothing, so the screen is not arranged and described again.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local capture = require('_widget_capture')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function frame()
    local dump = awesome._clay_tree(s)
    for line in dump:gmatch('[^\n]+') do
        if line:find('CLIENT BORDER_PAINT ', 1, true) then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
        end
    end
    error('no border client frame: ' .. dump)
end

local function border_pixel()
    local x, y, w, h = frame()
    return capture.read(s.content, math.floor(x + w - 2), math.floor(y + h / 2))
end

runner.run_async(function()
    local t = s.selected_tag
    t.layout, t.master_width_factor, t.gap = awful.layout.suit.tile, .5, 0
    beautiful.animation_layout_duration, beautiful.animation_tag_duration = 0, 0
    ruled.client.append_rule {rule = {class = 'BORDER_PAINT'},
        properties = {floating = false, border_width = 6, border_color = '#ff0000',
            titlebars_enabled = false, shadow = false}}
    awful.spawn {binary, 'BORDER_PAINT', os.tmpname(), '0', 'ff203040', '0'}
    local c = assert(async.wait_for_client('BORDER_PAINT', 2))
    async.sleep(.4)

    local r, g, b = border_pixel()
    assert(r > 240 and g < 15 and b < 15,
        string.format('border not red at the start: #%02x%02x%02x', r, g, b))

    local arranges = 0
    screen.connect_signal('arrange', function() arranges = arranges + 1 end)
    for _, color in ipairs {'#00ff00', '#0000ff', '#ffff00'} do
        c.border_color = color
        async.sleep(.2)
        local want = {tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16),
            tonumber(color:sub(6, 7), 16)}
        r, g, b = border_pixel()
        assert(math.abs(r - want[1]) < 16 and math.abs(g - want[2]) < 16
            and math.abs(b - want[3]) < 16,
            string.format('border %s not drawn: #%02x%02x%02x', color, r, g, b))
    end
    assert(arranges == 0, 'a border colour change arranged the screen ' .. arranges .. ' times')

    -- A width change still goes through the full describe.
    c.border_width = 12
    async.sleep(.3)
    assert(arranges > 0, 'a border width change did not arrange the screen')
    c.border_color = '#ff00ff'
    async.sleep(.2)
    r, g, b = border_pixel()
    assert(r > 240 and g < 15 and b > 240,
        string.format('wider border not repainted: #%02x%02x%02x', r, g, b))
    c:kill()
    runner.done()
end)
