-- vim: set ft=lua:

-- Choosing which devices to track, loaded by init.lua. It adds `deviceList`, `chooseDevices` and
-- `_devicesChanged`. What the picker shows and what a selection does is in presence.lua
-- (`pickerChoices`, `toggleDevice`); this file is the hs.chooser wiring around it.

return function(obj, presence)
	local SETTINGS_KEY = "ProximityLock.devices"
	local SCAN_SECONDS = 6

	--- ProximityLock:deviceList()
	--- Method
	--- The devices being tracked: whatever was last saved from the menu or `chooseDevices`, or else
	--- the `devices` variable.
	---
	--- Returns:
	---  * a list of `{ needle = ..., label = ... }` tables
	function obj:deviceList()
		local saved = hs.settings.get(SETTINGS_KEY)
		if saved then return saved end
		local list = {}
		for _, needle in ipairs(self.devices) do
			table.insert(list, { needle = needle, label = needle })
		end
		return list
	end

	function obj:_devicesChanged()
		local labels = {}
		for _, entry in ipairs(self:deviceList()) do
			table.insert(labels, entry.label)
		end
		self.log.f("Tracked devices: %s", #labels > 0 and table.concat(labels, ", ") or "none")
		if #labels == 0 then
			self:stop()
		elseif self:isRunning() then
			self:start()
		end
	end

	--- ProximityLock:chooseDevices([onClose])
	--- Method
	--- Listens for a few seconds, then shows the named devices in range. Selecting one adds it to the
	--- tracked devices, or removes it if it is already tracked (✓); the list stays open for more
	--- changes until dismissed. Locking restarts with the new list when the picker closes.
	---
	--- Parameters:
	---  * onClose - an optional function called once the picker has closed
	---
	--- Returns:
	---  * The ProximityLock object, for method chaining
	function obj:chooseDevices(onClose)
		if self._chooser then return self end
		local tracked, nearby, changed, closed = self:deviceList(), {}, false, false
		local chooser

		local function finish()
			if closed then return end
			closed = true
			chooser:delete()
			self._chooser = nil
			if changed then self:_devicesChanged() end
			if onClose then onClose() end
		end

		local function refresh() chooser:choices(presence.pickerChoices(tracked, nearby)) end

		chooser = hs.chooser.new(function(choice)
			if not choice then return end
			tracked = presence.toggleDevice(tracked, choice)
			hs.settings.set(SETTINGS_KEY, tracked)
			changed = true
			refresh()
			chooser:show()
		end)
		-- Selecting a row hides the chooser before it is shown again; only a hide that stays hidden
		-- means the picker was dismissed.
		chooser:hideCallback(function()
			self:_later(0.3, function()
				if not closed and not chooser:isVisible() then finish() end
			end)
		end)
		chooser:placeholderText("Select to track, ✓ to stop")
		chooser:searchSubText(true)
		self._chooser = chooser

		self:_notify(("Listening for nearby devices (%ds)…"):format(SCAN_SECONDS), SCAN_SECONDS)
		self:_scanNearby(SCAN_SECONDS, function(found)
			if not found then return finish() end
			nearby = found
			refresh()
			chooser:show()
		end)
		return self
	end
end
