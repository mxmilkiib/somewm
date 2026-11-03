-- Test: startup-notification tokens that cannot complete are released
--
--   * A spawn that fails to exec retracts the pending token with
--     spawn::canceled instead of letting it time out.
--   * A spawned process that exits without activating gets its token
--     expiry shortened to the post-exit grace, well under the 20s
--     timeout (so the spawn cursor stops being busy).
--
-- timeout: 20
local runner = require("_runner")
local spawn = require("awful.spawn")
local lgi = require("lgi")
local GLib = lgi.GLib

local events = {}
for _, sig in ipairs({ "spawn::initiated", "spawn::canceled",
                       "spawn::completed", "spawn::timeout" }) do
    awesome.connect_signal(sig, function(event)
        events[#events + 1] = {
            sig = sig,
            id = event.id,
            t = GLib.get_monotonic_time(),
        }
    end)
end

local function find(sig, id)
    for _, e in ipairs(events) do
        if e.sig == sig and e.id == id then
            return e
        end
    end
end

local bad_id, good_id, good_t0

runner.run_steps({
    function()
        -- Fails in spawn_exec: the binary does not exist.
        spawn.spawn("somewm-no-such-binary-xyz")
        -- Exits without ever activating.
        local pid, snid = spawn.spawn("true")
        assert(type(pid) == "number" and snid,
            "spawn of true failed: " .. tostring(pid))
        -- initiated is emitted synchronously, in spawn order.
        bad_id = events[1] and events[1].sig == "spawn::initiated"
            and events[1].id or nil
        good_id = events[2] and events[2].sig == "spawn::initiated"
            and events[2].id or nil
        assert(bad_id and good_id and bad_id ~= good_id,
            "expected two spawn::initiated events")
        good_t0 = GLib.get_monotonic_time()
        return true
    end,
    function()
        return find("spawn::canceled", bad_id) ~= nil
    end,
    function()
        local timeout = find("spawn::timeout", good_id)
        if not timeout then
            return
        end
        -- 20s would never arrive inside the wait window; the post-exit
        -- grace is what fired. Assert it anyway to pin the behaviour.
        assert(timeout.t - good_t0 < 15e6,
            "token survived past the exit grace")
        return true
    end,
}, { wait_per_step = 12 })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
