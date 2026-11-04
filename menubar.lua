-- vim: set ft=lua:

-- The menu bar item, loaded by init.lua, which documents the settings it reads. It adds
-- `_refreshMenubar` and `_removeMenubar` to the ProximityLock object. The icon is an open padlock
-- while the device is near and a closed one once it is judged away; the menu is built each time it
-- is opened, so it shows the status and limits as of that moment. While locking is off there is no
-- item at all; the hotkey, `setRunning` or the Wi-Fi automation turn it back on.

return function(obj)
	local STATUS_TEXT = {
		searching = "looking for the device",
		present = "device near",
		away = "device away, lock sent",
	}

	local function statusKey(self) return self._engine and self._engine:status() or "off" end

	local function menu(self)
		local items = { { title = "Status: " .. STATUS_TEXT[statusKey(self)], disabled = true } }
		local lines = self._engine and self._engine:describe(hs.timer.secondsSinceEpoch()) or {}
		for _, title in ipairs(lines) do
			table.insert(items, { title = title, disabled = true })
		end
		table.insert(items, { title = "-" })
		table.insert(items, { title = "Add or remove devices…", fn = function() self:chooseDevices() end })
		table.insert(items, { title = "Turn off", fn = function() self:toggle() end })
		return items
	end

	function obj:_refreshMenubar()
		if not self.showMenubar then return end
		local status = statusKey(self)
		if status == "off" then return self:_removeMenubar() end
		if not self._menubar then
			self._menubar = hs.menubar.new(true, self.name)
			self._menubar:setMenu(function() return menu(self) end)
		end
		if status == self._menubarStatus then return end
		self._menubarStatus = status
		local locked = status == "away"
		self._menubar:setIcon(
			hs.image.imageFromName(locked and "NSLockLockedTemplate" or "NSLockUnlockedTemplate"),
			true
		)
		self._menubar:setTooltip("ProximityLock: " .. STATUS_TEXT[status])
	end

	function obj:_removeMenubar()
		if self._menubar then self._menubar:delete() end
		self._menubar, self._menubarStatus = nil, nil
	end
end
