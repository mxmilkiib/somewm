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

local function client_x(class)
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*CLIENT ' .. (class or '%u+')) then
            local x = line:match('box (%-?%d+),%-?%d+ %d+x')
            if x then return tonumber(x) end
        end
    end
end

local function frames()
    return tonumber(dump():match('frames (%d+)'))
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
    local a = assert(async.wait_for_client('SLIDE_A', 2))
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

    -- The same return for a floating client, woken the way the tasklist
    -- does it: view the tag, then raise and focus through activate.
    a.floating = true
    a:geometry{x = 240, y = 140}
    async.sleep(.1)
    local wanted = a:geometry()
    for round = 1, 2 do
        other:view_only()
        async.sleep(.15)
        original:view_only()
        a.minimized = false
        a:emit_signal('request::activate', 'tasklist', {raise = true})
        async.sleep(.15)
        assert(client_x(), 'round ' .. round ..
            ': A lost its frame on the activate return: ' .. dump())
        local f1 = frames()
        async.sleep(.9)
        local f2 = frames()
        local x = assert(client_x(), 'round ' .. round ..
            ': A never settled: ' .. dump())
        assert(f2 > f1 or math.abs(x - wanted.x) <= 2, 'round ' .. round ..
            ': A wedged mid-slide at x=' .. x .. ' (frames ' ..
            f1 .. '->' .. f2 .. '): ' .. dump())
        assert(math.abs(x - wanted.x) <= 2, 'round ' .. round ..
            ': A settled at x=' .. x .. ' not ' .. wanted.x .. ': ' .. dump())
    end

    -- A client answering a new configured size with a stale buffer rides
    -- the chrome path: the frame Clay solves reads back into its geometry,
    -- so a floating client's slide-back must not feed the box it is still
    -- moving into the next declaration.
    ruled.client.append_rule {
        rule = {class = 'SLIDE_C'},
        properties = {border_width = 0, floating = true},
    }
    awful.spawn{binary, 'SLIDE_C', report, '0', '0000ffcc', '0', '0', '0', '0', '9'}
    local cc = assert(async.wait_for_client('SLIDE_C', 2))
    async.sleep(.3)
    cc:geometry{x = 400, y = 200, width = 300, height = 300}
    async.sleep(.3)
    assert(cc._committed_size, 'C never committed a stale size: ' .. dump())
    other:view_only()
    async.sleep(.15)
    original:view_only()
    cc.minimized = false
    cc:emit_signal('request::activate', 'tasklist', {raise = true})
    async.sleep(.15)
    assert(client_x('SLIDE_C'), 'C lost its frame on the activate return: ' .. dump())
    async.sleep(1.2)
    local x = assert(client_x('SLIDE_C'), 'C never settled: ' .. dump())
    assert(math.abs(x - 400) <= 2,
        'C wedged mid-slide at x=' .. x .. ' (geometry ' ..
        tostring(cc:geometry().x) .. '): ' .. dump())
    assert(math.abs(cc:geometry().x - 400) <= 2,
        'C geometry polluted to ' .. tostring(cc:geometry().x) .. ': ' .. dump())

    io.stderr:write('[PASS] a returning client drops its tag slide ghost\n')
    runner.done()
end)
