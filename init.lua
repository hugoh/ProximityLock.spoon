-- vim: set ft=lua:

--- === ProximityLock ===
---
--- A Hammerspoon Spoon that locks the Mac when your Bluetooth LE devices (phone, watch) go out of
--- range. It listens to the devices' advertisements through a small scanner app, smooths the RSSI
--- with a Kalman filter and only locks after the signal stays weak (or silent) for a while, so brief
--- dips and missed advertisements don't trigger a lock. With several devices it locks when any one
--- of them is away (or, if you prefer, only when all are). It never unlocks.
---
--- The scanner is compiled from `scan.swift` the first time it is needed, which takes a few seconds
--- and requires the Xcode command line tools.
---
--- Download: https://github.com/hugoh/ProximityLock.spoon/releases/latest

local obj = {}
obj.__index = obj

obj.name = "ProximityLock"
obj.version = "dev"
obj.author = "Hugo Haas"
obj.license = "MIT"
obj.homepage = "https://github.com/hugoh/ProximityLock.spoon"

--- ProximityLock.devices
--- Variable
--- Devices to track, as a list of text matched (case-insensitive substring) against each device's
--- advertised name or CoreBluetooth identifier. Used until you choose devices from the menu (or with
--- `chooseDevices`); after that the chosen list is remembered and takes over. If none are set,
--- `start()` opens the picker.
obj.devices = {}

--- ProximityLock.lockThreshold
--- Variable
--- Smoothed RSSI in dBm under which a device counts as far away (default: -75).
obj.lockThreshold = -75

--- ProximityLock.lockDelay
--- Variable
--- Seconds a device's smoothed signal must stay under `lockThreshold` before it counts as away
--- (default: 10).
obj.lockDelay = 10

--- ProximityLock.missTimeout
--- Variable
--- Seconds without any advertisement from a device before it counts as away (default: 60).
obj.missTimeout = 60

--- ProximityLock.lockWhen
--- Variable
--- With several devices: "any" (default) locks as soon as one of them is away, so leaving a phone
--- on the desk doesn't keep the Mac open after you walk off with your watch; "all" locks only when
--- every device is away, so a phone left in another room doesn't lock you out while your watch is
--- with you. Either way it never unlocks.
obj.lockWhen = "any"

--- ProximityLock.lockWarning
--- Variable
--- Seconds of on-screen countdown before locking, during which Esc cancels the lock (default: 3).
--- 0 locks immediately. Cancelling skips that lock and starts the signal assessment over, so it
--- locks again after the usual delays if the devices really are gone.
obj.lockWarning = 3

--- ProximityLock.onAway
--- Variable
--- Function called to lock when the devices are judged away, after the warning (default: locks the
--- screen).
obj.onAway = function() hs.caffeinate.lockScreen() end

--- ProximityLock.showMenubar
--- Variable
--- Show a menu bar item with an open or closed padlock, the status and the current limits, and menu
--- entries to choose devices and turn locking off. The item is hidden while locking is off
--- (default: true).
obj.showMenubar = true

--- ProximityLock.logLevel
--- Variable
--- Log level: "info" (default) logs the decisions; "debug" also logs every sample with the
--- smoothed value, the filter gain, and the weak/strong/silence timers.
obj.logLevel = "info"

obj.log = hs.logger.new("ProximityLock", "info")

local presence = dofile(hs.spoons.resourcePath("presence.lua"))
dofile(hs.spoons.resourcePath("scanner.lua"))(obj, presence)
dofile(hs.spoons.resourcePath("warning.lua"))(obj)
dofile(hs.spoons.resourcePath("picker.lua"))(obj, presence)
dofile(hs.spoons.resourcePath("menubar.lua"))(obj)

local CONFIG_KEYS = {
	"devices",
	"lockThreshold",
	"lockDelay",
	"missTimeout",
	"lockWhen",
	"lockWarning",
	"onAway",
	"showMenubar",
	"logLevel",
}

--- ProximityLock:configure(opts)
--- Method
--- Sets one or more of ProximityLock's variables from a table. Call it before `start()`.
---
--- Parameters:
---  * opts - a table with any of the variable names documented on this page as keys
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:configure(opts)
	for _, key in ipairs(CONFIG_KEYS) do
		if opts[key] ~= nil then self[key] = opts[key] end
	end
	if opts.logLevel then self.log.setLogLevel(opts.logLevel) end
	return self
end

--- ProximityLock:start()
--- Method
--- Starts the scanner and the presence checks. With no devices to track it opens the device picker
--- first and starts once you have chosen some.
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:start()
	local devices = self:deviceList()
	if #devices == 0 then
		self.log.w("No devices to track; opening the device picker")
		return self:chooseDevices(function()
			if #self:deviceList() > 0 then self:start() end
		end)
	end

	self:stop()
	self._buffer, self._lastTick = "", nil
	self._engine = presence.newGroup({
		lockThreshold = self.lockThreshold,
		lockDelay = self.lockDelay,
		missTimeout = self.missTimeout,
		lockWhen = self.lockWhen,
		log = function(message) self.log.d(message) end,
		onAway = function(reason)
			self.log.i("Away: " .. reason)
			self:_lockWithWarning()
		end,
		onReturn = function(reason) self.log.i("Back: " .. reason) end,
	}, devices, hs.timer.secondsSinceEpoch())
	-- hs.timer silently stops a repeating timer whose callback throws, which would end all locking.
	-- So nothing may escape, not even from reporting the error (a plain pcall has no handler that
	-- could itself fail, and the report is protected too).
	self._ticker = hs.timer.doEvery(1, function()
		local ok, err = pcall(function() self:_tick(hs.timer.secondsSinceEpoch()) end)
		if not ok then pcall(self.log.e, "Tick failed: " .. tostring(err)) end
	end)
	self._wakeWatcher = hs.caffeinate.watcher
		.new(function(event)
			if event == hs.caffeinate.watcher.systemDidWake and self._engine then self:_onWake() end
		end)
		:start()
	self:_startScanner()
	self:_refreshMenubar()

	local labels = {}
	for _, device in ipairs(devices) do
		table.insert(labels, device.label)
	end
	self.log.f(
		"Started %s v%s: tracking %s (lock when %s is away); locks under %g dBm for %gs or after %gs of silence",
		self.name,
		self.version,
		table.concat(labels, ", "),
		self.lockWhen,
		self.lockThreshold,
		self.lockDelay,
		self.missTimeout
	)
	return self
end

--- ProximityLock:stop()
--- Method
--- Stops the scanner and the presence checks.
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:stop()
	self:_endWarning()
	if self._engine then self.log.f("Stopped %s v%s", self.name, self.version) end
	if self._ticker then self._ticker:stop() end
	if self._wakeWatcher then self._wakeWatcher:stop() end
	if self._restart then self._restart:stop() end
	if self._scanner then
		self._scanner:setCallback(nil)
		self._scanner:terminate()
	end
	self:_killScanner()
	self._ticker, self._wakeWatcher, self._restart, self._scanner, self._engine = nil, nil, nil, nil, nil
	if self._menubar then self:_refreshMenubar() end
	return self
end

--- ProximityLock:isRunning()
--- Method
--- Returns:
---  * true while the scanner and presence checks are on
function obj:isRunning() return self._engine ~= nil end

--- ProximityLock:setRunning(on)
--- Method
--- Turns locking on or off, doing nothing if it is already in that state. Meant for automation, e.g.
--- from a MacWatcher Wi-Fi hook that turns it off at home.
---
--- Parameters:
---  * on - true to start, false to stop
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:setRunning(on)
	if on and not self:isRunning() then
		self:start()
	elseif not on and self:isRunning() then
		self:stop()
	end
	return self
end

--- ProximityLock:toggle()
--- Method
--- Turns locking off if it is on, and on if it is off.
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:toggle()
	self:setRunning(not self:isRunning())
	hs.alert.show("ProximityLock " .. (self:isRunning() and "on" or "off"))
	return self
end

--- ProximityLock:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for ProximityLock.
---
--- Parameters:
---  * mapping - a table with a `toggle` key mapped to a `{ {modifiers}, key }` spec
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:bindHotkeys(mapping)
	if self._hotkey then self._hotkey:delete() end
	if mapping.toggle then
		self._hotkey = hs.hotkey.bind(mapping.toggle[1], mapping.toggle[2], function() self:toggle() end)
	end
	return self
end

--- ProximityLock:init()
--- Method
--- Called automatically by `hs.loadSpoon()`. Logs the loaded version.
---
--- Returns:
---  * The ProximityLock object, for method chaining
function obj:init()
	self.log.f("Loaded %s v%s", self.name, self.version)
	-- Deferred so configure() has set showMenubar by the time the item is created.
	self:_later(0, function() self:_refreshMenubar() end)
	return self
end

return obj
