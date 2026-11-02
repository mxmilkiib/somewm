-- A layer surface that names no output must land on the monitor under the
-- parked cursor even when an output-manager apply reorders the layout
-- underneath it. updatemons() re-clamps the pointer with wlr_cursor_move(),
-- which generates no motion event, so selmon stayed on the stale monitor and
-- rofi opened on the internal panel after kanshi applied its login profile.
-- Drives real wlr-randr applies against the test instance: n2 slides onto
-- the cursor's coordinates, then n1 slides away - the point is always
-- covered, so the parked cursor deterministically ends inside n2. Needs
-- two outputs (the two-output lane in tests/README.md) and wlr-randr on
-- PATH.

local awful  = require("awful")
local runner = require("_runner")
local utils  = require("_utils")

if screen.count() < 2 then
    return runner.skip("test-layer-surface-follows-output-move requires WLR_HEADLESS_OUTPUTS=2")
end

local LAYER_CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
if not LAYER_CLIENT then return end

local rc = os.execute("command -v wlr-randr >/dev/null 2>&1")
if rc ~= 0 and rc ~= true then
    return runner.skip("wlr-randr not found on PATH")
end

local NAMESPACE = "test-follows-output-move"
local s1, s2, n1, n2, g1, g2, newx
local pid

local function find_surface()
    for _, ls in ipairs(layer_surface.get()) do
        if ls.namespace == NAMESPACE then return ls end
    end
end

local function output_name(s)
    for k, v in pairs(s.outputs) do
        if type(v) == "table" and v.name then return v.name end
        if type(k) == "string" then return k end
    end
end

local function pos(x, y)
    return string.format("%d,%d", math.floor(x + 0.5), math.floor(y + 0.5))
end

local function randr(output, x, y)
    awful.spawn(string.format("wlr-randr --output %s --pos %s",
        output, pos(x, y)))
end

runner.run_steps({
    function()
        s1, s2 = screen[1], screen[2]
        g1, g2 = s1.geometry, s2.geometry
        n1, n2 = output_name(s1), output_name(s2)
        newx = g2.x + g2.width + 512
        io.stderr:write(string.format(
            "[TEST] %s at %s, %s at %s\n", n1, pos(g1.x, g1.y), n2, pos(g2.x, g2.y)))
        return (n1 ~= nil and n2 ~= nil) or nil
    end,
    -- Park the cursor just inside screen 1's corner.
    function()
        root.fake_input("motion_notify", false, g1.x + 16, g1.y + 16)
        return mouse.screen == s1 or nil
    end,
    -- Slide n2 onto the cursor's coordinates: the outputs overlap there
    -- and the point stays covered, so no clamp happens.
    function()
        randr(n2, g1.x, g1.y)
        return true
    end,
    function()
        return (s2.geometry.x == g1.x and s2.geometry.y == g1.y) or nil
    end,
    -- Slide n1 away: the cursor's coordinates are inside n2 now, so the
    -- pointer never moves and never emits a motion event. selmon must
    -- notice the monitor underneath changed anyway.
    function()
        randr(n1, newx, g1.y)
        return true
    end,
    function()
        return (s1.geometry.x == newx and s1.geometry.y == g1.y) or nil
    end,
    function()
        if mouse.screen ~= s2 then return nil end
        local c = mouse.coords()
        io.stderr:write(string.format(
            "[TEST] cursor %.0f,%.0f mouse.screen=%d; spawning layer client\n",
            c.x, c.y, mouse.screen.index))
        pid = awful.spawn(LAYER_CLIENT .. " --namespace " .. NAMESPACE .. " --keyboard none")
        return true
    end,
    function()
        local ls = find_surface()
        if not ls or not ls.screen then return nil end
        assert(ls.screen == s2, string.format(
            "layer surface opened on screen %d, parked cursor is on screen %d",
            ls.screen.index, s2.index))
        awesome.kill(pid, 9)
        return true
    end,
    function()
        local ls = find_surface()
        return (not ls or not ls.valid) or nil
    end,
    -- Restore the original layout for later tests in the lane: bring n1
    -- back first so the cursor's coordinates stay covered throughout.
    function()
        randr(n1, g1.x, g1.y)
        return true
    end,
    function()
        return (s1.geometry.x == g1.x and s1.geometry.y == g1.y) or nil
    end,
    function()
        randr(n2, g2.x, g2.y)
        return true
    end,
    function()
        return (s2.geometry.x == g2.x and s2.geometry.y == g2.y) or nil
    end,
}, { kill_clients = false })
