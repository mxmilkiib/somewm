---------------------------------------------------------------------------
-- The `align` layout has three slots for child widgets. On its main axis, it
-- will use as much space as is available to it and distribute that to its child
-- widgets by stretching or shrinking them based on the chosen @{expand}
-- strategy.
-- On its secondary axis, the biggest child widget determines the size of the
-- layout, but smaller widgets will not be stretched to match it.
--
-- In its default configuration, the layout will give the first and third
-- widgets only the minimum space they ask for and it aligns them to the outer
-- edges. The remaining space between them is made available to the widget in
-- slot two.
--
-- This layout is most commonly used to split content into left/top, center and
-- right/bottom sections. As such, it is usually seen as the root layout in
-- @{awful.wibar}.
--
-- You may also fill just one or two of the widget slots, the @{expand} algorithm
-- will adjust accordingly.
--
--@DOC_wibox_layout_defaults_align_EXAMPLE@
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @layoutmod wibox.layout.align
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local table = table
local pairs = pairs
local floor = math.floor
local gtable = require("gears.table")
local base = require("wibox.widget.base")

local align = {}

-- Calculate the layout of an align layout.
-- @param context The context in which we are drawn.
-- @param width The available width.
-- @param height The available height.
function align:layout(context, width, height)
    local result = {}

    -- Draw will have to deal with all three align modes and should work in a
    -- way that makes sense if one or two of the widgets are missing (if they
    -- are all missing, it won't draw anything.) It should also handle the case
    -- where the fit something that isn't set to expand (for instance the
    -- outside widgets when the expand mode is "inside" or any of the widgets
    -- when the expand mode is "none" wants to take up more space than is
    -- allowed.
    local size_first = 0
    -- start with all the space given by the parent, subtract as we go along
    local size_remains = self._private.dir == "y" and height or width
    -- This is only set & used if expand ~= "inside" and we have second width.
    -- It contains the size allocated to the second widget.
    local size_second

    -- we will prioritize the middle widget unless the expand mode is "inside"
    --  if it is, we prioritize the first widget by not doing this block also,
    --  if the second widget doesn't exist, we will prioritise the first one
    --  instead
    if self._private.expand ~= "inside" and self._private.second then
        local w, h = base.fit_widget(self, context, self._private.second, width, height)
        size_second = self._private.dir == "y" and h or w
        -- if all the space is taken, skip the rest, and draw just the middle
        -- widget
        if size_second >= size_remains then
            return { base.place_widget_at(self._private.second, 0, 0, width, height) }
        else
            -- the middle widget is sized first, the outside widgets are given
            --  the remaining space if available we will draw later
            size_remains = floor((size_remains - size_second) / 2)
        end
    end
    if self._private.first then
        local w, h, _ = width, height, nil
        -- we use the fit function for the "inside" and "none" modes, but
        --  ignore it for the "outside" mode, which will force it to expand
        --  into the remaining space
        if self._private.expand ~= "outside" then
            if self._private.dir == "y" then
                _, h = base.fit_widget(self, context, self._private.first, width, size_remains)
                size_first = h
                -- for "inside", the third widget will get a chance to use the
                --  remaining space, then the middle widget. For "none" we give
                --  the third widget the remaining space if there was no second
                --  widget to take up any space (as the first if block is skipped
                --  if this is the case)
                if self._private.expand == "inside" or not self._private.second then
                    size_remains = size_remains - h
                end
            else
                w, _ = base.fit_widget(self, context, self._private.first, size_remains, height)
                size_first = w
                if self._private.expand == "inside" or not self._private.second then
                    size_remains = size_remains - w
                end
            end
        else
            if self._private.dir == "y" then
                h = size_remains
            else
                w = size_remains
            end
        end
        table.insert(result, base.place_widget_at(self._private.first, 0, 0, w, h))
    end
    -- size_remains will be <= 0 if first used all the space
    if self._private.third and size_remains > 0 then
        local w, h, _ = width, height, nil
        if self._private.expand ~= "outside" then
            if self._private.dir == "y" then
                _, h = base.fit_widget(self, context, self._private.third, width, size_remains)
                -- give the middle widget the rest of the space for "inside" mode
                if self._private.expand == "inside" then
                    size_remains = size_remains - h
                end
            else
                w, _ = base.fit_widget(self, context, self._private.third, size_remains, height)
                if self._private.expand == "inside" then
                    size_remains = size_remains - w
                end
            end
        else
            if self._private.dir == "y" then
                h = size_remains
            else
                w = size_remains
            end
        end
        local x, y = width - w, height - h
        table.insert(result, base.place_widget_at(self._private.third, x, y, w, h))
    end
    -- here we either draw the second widget in the space set aside for it
    -- in the beginning, or in the remaining space, if it is "inside"
    if self._private.second and size_remains > 0 then
        local x, y, w, h = 0, 0, width, height
        if self._private.expand == "inside" then
            if self._private.dir == "y" then
                h = size_remains
                x, y = 0, size_first
            else
                w = size_remains
                x, y = size_first, 0
            end
        else
            local _
            if self._private.dir == "y" then
                _, h = base.fit_widget(self, context, self._private.second, width, size_second)
                y = floor( (height - h)/2 )
            else
                w, _ = base.fit_widget(self, context, self._private.second, size_second, height)
                x = floor( (width -w)/2 )
            end
        end
        table.insert(result, base.place_widget_at(self._private.second, x, y, w, h))
    end
    return result
end

--- The widget in slot one.
--
-- This is the widget that is at the left/top.
--
-- @property first
-- @tparam[opt=nil] widget|nil first
-- @propertytype nil This spot will be empty. Depending on how large the second
--  widget is an and the value of `expand`, it might mean it will leave an empty
--  area.
-- @propemits true false

function align:set_first(widget)
    if self._private.first == widget then
        return
    end
    self._private.first = widget
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::first", widget)
end

--- The widget in slot two.
--
-- This is the centered one.
--
-- @property second
-- @tparam[opt=nil] widget|nil second
-- @propertytype nil When this property is `nil`, then there will be an empty
--  area.
-- @propemits true false

function align:set_second(widget)
    if self._private.second == widget then
        return
    end
    self._private.second = widget
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::second", widget)
end

--- The widget in slot three.
--
-- This is the widget that is at the right/bottom.
--
-- @property third
-- @tparam[opt=nil] widget|nil third
-- @propertytype nil This spot will be empty. Depending on how large the second
--  widget is an and the value of `expand`, it might mean it will leave an empty
--  area.
-- @propemits true false

function align:set_third(widget)
    if self._private.third == widget then
        return
    end
    self._private.third = widget
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::third", widget)
end

for _, prop in ipairs {"first", "second", "third", "expand" } do
    align["get_"..prop] = function(self)
        return self._private[prop]
    end
end

function align:get_children()
    return gtable.from_sparse {self._private.first, self._private.second, self._private.third}
end

function align:set_children(children)
    self:set_first(children[1])
    self:set_second(children[2])
    self:set_third(children[3])
end

-- Fit the align layout into the given space. The align layout will
-- ask for the sum of the sizes of its sub-widgets in its direction
-- and the largest sized sub widget in the other direction.
-- @param context The context in which we are fit.
-- @param orig_width The available width.
-- @param orig_height The available height.
function align:fit(context, orig_width, orig_height)
    local used_in_dir = 0
    local used_in_other = 0

    for _, v in pairs{self._private.first, self._private.second, self._private.third} do
        local w, h = base.fit_widget(self, context, v, orig_width, orig_height)

        local max = self._private.dir == "y" and w or h
        if max > used_in_other then
            used_in_other = max
        end

        used_in_dir = used_in_dir + (self._private.dir == "y" and h or w)
    end

    if self._private.dir == "y" then
        return used_in_other, used_in_dir
    end
    return used_in_dir, used_in_other
end

--- Set the expand mode, which determines how child widgets expand to take up
-- unused space.
--
-- Attempting to set any other value than one of those three will fall back to
-- `"inside"`.
--
-- @property expand
-- @tparam[opt="inside"] string expand How to use unused space.
-- @propertyvalue "inside" The widgets in slot one and three are set to their minimal
--   required size. The widget in slot two is then given the remaining space.
--   This is the default behaviour.
-- @propertyvalue "outside" The widget in slot two is set to its minimal required size and
--   placed in the center of the space available to the layout. The other
--   widgets are then given the remaining space on either side.
--   If the center widget requires all available space, the outer widgets are
--   not drawn at all.
-- @propertyvalue "none" All widgets are given their minimal required size or the
--   remaining space, whichever is smaller. The center widget gets priority.

function align:set_expand(mode)
    if mode == "none" or mode == "outside" then
        self._private.expand = mode
    else
        self._private.expand = "inside"
    end
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::expand", mode)
end

function align:reset()
    for _, v in pairs({ "first", "second", "third" }) do
        self[v] = nil
    end
    self:emit_signal("widget::layout_changed")
end

local function get_layout(dir, first, second, third)
    local ret = base.make_widget(nil, nil, {enable_properties = true})
    ret._private.dir = dir

    gtable.crush(ret, align, true)

    ret:set_expand("inside")
    ret:set_first(first)
    ret:set_second(second)
    ret:set_third(third)

    -- An align layout allow set_children to have empty entries
    ret.allow_empty_widget = true

    return ret
end

--- Returns a new horizontal align layout.
--
-- The three widget slots are aligned left, center and right.
--
-- Additionally, this creates the aliases `set_left`, `set_middle` and
-- `set_right` to assign @{first}, @{second} and @{third} respectively.
-- @constructorfct wibox.layout.align.horizontal
-- @tparam[opt] widget left Widget to be put in slot one.
-- @tparam[opt] widget middle Widget to be put in slot two.
-- @tparam[opt] widget right Widget to be put in slot three.
function align.horizontal(left, middle, right)
    local ret = get_layout("x", left, middle, right)

    rawset(ret, "set_left"  , ret.set_first  )
    rawset(ret, "set_middle", ret.set_second )
    rawset(ret, "set_right" , ret.set_third  )

    return ret
end

--- Returns a new vertical align layout.
--
-- The three widget slots are aligned top, center and bottom.
--
-- Additionally, this creates the aliases `set_top`, `set_middle` and
-- `set_bottom` to assign @{first}, @{second} and @{third} respectively.
-- @constructorfct wibox.layout.align.vertical
-- @tparam[opt] widget top Widget to be put in slot one.
-- @tparam[opt] widget middle Widget to be put in slot two.
-- @tparam[opt] widget bottom Widget to be put in slot three.
function align.vertical(top, middle, bottom)
    local ret = get_layout("y", top, middle, bottom)

    rawset(ret, "set_top"   , ret.set_first  )
    rawset(ret, "set_middle", ret.set_second )
    rawset(ret, "set_bottom", ret.set_third  )

    return ret
end

--@DOC_fixed_COMMON@

--- wibox.layout.align -> three children along the direction, sized as the
-- `expand` mode says: fit for the slots the engine asked `:fit`, grow for
-- the ones it gave what was left. Empty elements stand in where the engine
-- leaves space: a grow spacer where a missing second widget would have
-- been, and in "none" mode a grow wrapper around each outer widget, aligned
-- to its edge, so the second centers in the whole width as the engine
-- centers it.
--
-- A slot that grows starts at the size of what it holds and is only ever
-- given more (clay.h:1815-1827 sums a child's content, 2357-2391 grows),
-- and the compress pass will not take it below that content
-- (clay.h:2334-2338). So a grown slot whose own subtree converted keeps a
-- content width larger than the share the engine would have given it, and
-- takes that width from the slots beside it.
local function describe_align(w)
    local p = w._private

    if w.layout ~= align.layout then
        return nil
    end

    local along, across = "w", "h"

    if p.dir == "y" then
        along, across = "h", "w"
    end

    local function slot(widget, sizing)
        return { widget = widget, [along] = sizing, [across] = "grow" }
    end

    local specs = {}
    local node = { dir = p.dir, specs = specs }

    -- "outside" with no second widget gives both outer widgets the whole
    -- length, one over the other, which two elements in a row cannot say.
    if p.expand == "outside" and not p.second then
        if p.first or p.third then
            return nil
        end
        return node
    end

    if p.expand == "inside" or not p.second then
        -- The outer widgets at their fit; the second grows between. With
        -- no second widget the third still sits at the far edge.
        if p.first then
            specs[#specs + 1] = slot(p.first, "fit")
        end
        if p.second then
            specs[#specs + 1] = slot(p.second, "grow")
        elseif p.third then
            specs[#specs + 1] = { [along] = "grow" }
        end
        if p.third then
            specs[#specs + 1] = slot(p.third, "fit")
        end
        return node
    end

    if p.expand == "outside" then
        -- The second at its fit; the outer widgets take what it leaves,
        -- splitting it evenly unless one of them holds converted content
        -- wider than its half. A missing one leaves its half empty.
        specs[1] = p.first and slot(p.first, "grow") or { [along] = "grow" }
        specs[2] = slot(p.second, "fit")
        specs[3] = p.third and slot(p.third, "grow") or { [along] = "grow" }
        return node
    end

    -- "none": the second at its fit, the outer widgets at theirs, each
    -- pinned to its edge of a half that grows.
    specs[1] = { [along] = "grow", [across] = "grow",
        align = { x = "left", y = "top" },
        children = { p.first and slot(p.first, "fit") } }
    specs[2] = slot(p.second, "fit")
    specs[3] = { [along] = "grow", [across] = "grow",
        align = p.dir == "y" and { x = "left", y = "bottom" }
            or { x = "right", y = "top" },
        children = { p.third and slot(p.third, "fit") } }
    return node
end

align._clay = { describe = describe_align, fit = align.fit }

return align

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
