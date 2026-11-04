-- vim: set ft=lua:

-- The countdown before a lock, loaded by init.lua. It adds `_lockWithWarning`, `_endWarning` and
-- `cancelLock`. A small notice counts down, Esc cancels it (enabled only while it runs), and the lock
-- happens at the end only if the devices are still judged away. Cancelling skips that lock and starts
-- the assessment over (`rearm`), so if the devices really are gone it locks again after the usual
-- delays rather than waiting for them to return first.

return function(obj)
	-- Opaque, so the contrast does not depend on what is behind it; white on this red is about 8:1
	-- (spec/warning_spec.lua checks the ratio).
	local WARNING_STYLE = {
		fillColor = { red = 0.65, green = 0.05, blue = 0.05, alpha = 1 },
		textColor = { white = 1, alpha = 1 },
	}

	local function screenIsLocked() return (hs.caffeinate.sessionProperties() or {}).CGSSessionScreenIsLocked == true end

	function obj:_endWarning()
		local warning = self._warning
		if not warning then return end
		self._warning = nil
		if warning.timer then warning.timer:stop() end
		if warning.escape then warning.escape:delete() end
		if warning.notice then hs.alert.closeSpecific(warning.notice) end
	end

	--- ProximityLock:cancelLock()
	--- Method
	--- Cancels the lock that is counting down, if any, and starts the signal assessment over. Esc does
	--- this during the countdown; this is for binding your own key.
	---
	--- Returns:
	---  * true if a countdown was cancelled
	function obj:cancelLock()
		if not self._warning then return false end
		self:_endWarning()
		if self._engine then self._engine:rearm(hs.timer.secondsSinceEpoch()) end
		self.log.i("Lock cancelled; reassessing from scratch")
		return true
	end

	-- Locks, and if that fails starts the assessment over so the lock is tried again rather than
	-- never happening: the engine has already judged the devices away and would not ask twice.
	function obj:_lock()
		local ok, err = pcall(self.onAway)
		if ok then return end
		pcall(self.log.e, "Locking failed: " .. tostring(err))
		if self._engine then self._engine:rearm(hs.timer.secondsSinceEpoch()) end
	end

	-- Runs `onAway` after the `lockWarning` countdown, or at once if the warning is off or the screen
	-- is already locked.
	function obj:_lockWithWarning()
		if self._warning then return end
		if self.lockWarning <= 0 or screenIsLocked() then
			self.log.i("Locking now")
			return self:_lock()
		end
		self.log.i(("Locking in %gs unless cancelled"):format(self.lockWarning))

		local remaining = self.lockWarning
		local warning = {}
		self._warning = warning

		local function show()
			if warning.notice then hs.alert.closeSpecific(warning.notice) end
			warning.notice = self:_notify(
				("ProximityLock: locking in %d… (Esc to cancel)"):format(math.ceil(remaining)),
				remaining + 1,
				WARNING_STYLE
			)
		end

		-- hs.timer silently stops a repeating timer whose callback throws, which here would leave Esc
		-- captured; so nothing may escape, not even from the error report.
		local function tick()
			local ok, err = pcall(function()
				remaining = remaining - 1
				if remaining > 0 then return show() end
				local stillAway = self._engine ~= nil and self._engine:status() == "away"
				self:_endWarning()
				if stillAway then
					self:_lock()
				else
					self.log.i("Lock skipped: the devices are no longer away")
				end
			end)
			if not ok then
				pcall(function() self:_endWarning() end)
				pcall(self.log.e, "Locking failed: " .. tostring(err))
			end
		end

		-- If the countdown cannot be set up, the devices are still away: lock rather than leave Esc
		-- captured and every later lock blocked by the half-made warning.
		local ok, err = pcall(function()
			warning.escape = hs.hotkey.new({}, "escape", function() self:cancelLock() end):enable()
			show()
			warning.timer = hs.timer.doEvery(1, tick)
		end)
		if not ok then
			pcall(function() self:_endWarning() end)
			pcall(self.log.e, "Warning failed: " .. tostring(err))
			self:_lock()
		end
	end
end
