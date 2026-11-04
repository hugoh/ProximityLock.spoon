-- Presence engine: smooths noisy BLE RSSI with a Kalman filter, then decides away/present
-- with dwell timers and hysteresis. Pure Lua with injected time, so it is testable without hs.

local M = {}

-- Kalman filter noise, chosen for a phone at a desk (readings every ~1-3 s, about +-5 dB of jitter)
-- rather than tuned against recorded data. To change how the smoothing behaves, edit these two numbers:
--   q, process variance in dB^2 per second: how fast the real signal may drift (you walking).
--        Raise it to follow movement faster, lower it to smooth more.
--   r, measurement variance in dB^2: how noisy a single reading is. Raise it to trust readings
--        less (smoother), lower it to trust them more.
-- Only the ratio q/r matters much. The values 4/25 and 0.25/25 gave roughly a 3 s and a 10 s
-- settling time, against about 5 s for 1/25.
local NOISE = { q = 1, r = 25 }

M.defaults = {
	lockThreshold = -75,
	returnHysteresis = 8,
	lockDelay = 10,
	returnDelay = 3,
	missTimeout = 30,
	lockWhen = "any",
}

-- CoreBluetooth often reports one advertisement twice in the same instant; counting both would
-- double its weight in the filter.
local DUPLICATE_WINDOW = 0.1

local Engine = {}
Engine.__index = Engine

function Engine:_log(format, ...)
	if self.log then self.log(format:format(...)) end
end

function M.new(opts, now)
	local self = setmetatable({}, Engine)
	for key, value in pairs(M.defaults) do
		self[key] = value
	end
	for key, value in pairs(opts or {}) do
		self[key] = value
	end
	self.noise = NOISE
	self.state = "present"
	self.lastSeen = now
	return self
end

-- Variance grows with the time since the last sample, so the gain rises after a gap and the
-- first fresh reading is trusted more than one arriving in a steady stream.
function Engine:feed(now, rssi)
	if self.lastSample and now - self.lastSample < DUPLICATE_WINDOW then
		self:_log("sample rssi=%d ignored (duplicate within %.1fs)", rssi, DUPLICATE_WINDOW)
		self.lastSeen = now
		return
	end
	if not self.estimate then
		self.estimate, self.variance = rssi, self.noise.r
		self:_log("sample rssi=%d est=%.1f (first sample)", rssi, self.estimate)
	else
		local gap = now - self.lastSample
		local predicted = self.variance + self.noise.q * gap
		local gain = predicted / (predicted + self.noise.r)
		self.estimate = self.estimate + gain * (rssi - self.estimate)
		self.variance = (1 - gain) * predicted
		self:_log("sample rssi=%d est=%.1f gain=%.2f gap=%.1fs", rssi, self.estimate, gain, gap)
	end
	self.lastSample, self.lastSeen = now, now
end

local function dwelled(self, field, condition, now, delay, what)
	if not condition then
		if self[field] then self:_log("%s ended after %.0fs (est=%.1f)", what, now - self[field], self.estimate) end
		self[field] = nil
		return false
	end
	if not self[field] then
		self[field] = now
		self:_log("%s began (est=%.1f); acts in %gs unless it ends", what, self.estimate, delay)
	end
	return now - self[field] >= delay
end

-- One device's state for the menu: the smoothed signal once known, else why there is none.
function Engine:signalText(now)
	if not self.estimate then return self.state == "away" and "away, no readings" or "searching" end
	local text = ("≈%.0f dBm, seen %.0fs ago"):format(self.estimate, now - self.lastSeen)
	return self.state == "away" and text .. ", away" or text
end

-- For when nothing was listening (the Mac slept, the scanner restarted): the silence says nothing
-- about the device, and the old estimate is stale, so both start over.
function Engine:resetSilence(now)
	self.lastSeen, self.lastSample, self.estimate, self.variance = now, nil, nil, nil
	self.weakSince, self.strongSince, self.silenceBucket = nil, nil, 0
	self:_log("silence clock and estimate reset")
end

-- Starts the assessment over as if the device had just been switched on: no estimate, fresh timers,
-- and present (not away) until the signal gives a reason to be otherwise. Used after a cancelled lock.
function Engine:rearm(now)
	self:resetSilence(now)
	self.state = "present"
end

function Engine:status()
	if self.state == "present" and not self.estimate then return "searching" end
	return self.state
end

function Engine:_transition(state, callback, reason)
	self.state, self.weakSince, self.strongSince = state, nil, nil
	self:_log("%s: %s", state, reason)
	if callback then callback(reason) end
end

function Engine:_logSilence(now)
	local bucket = math.floor((now - self.lastSeen) / 5)
	if bucket > 0 and bucket ~= self.silenceBucket then
		self:_log("no sample for %ds (locks at %gs)", bucket * 5, self.missTimeout)
	end
	self.silenceBucket = bucket
end

function Engine:tick(now)
	local fresh = now - self.lastSeen < self.missTimeout
	if self.state == "present" then
		self:_logSilence(now)
		local weak = self.estimate ~= nil and self.estimate < self.lockThreshold
		if not fresh then
			self:_transition("away", self.onAway, ("no sample for %.0fs"):format(now - self.lastSeen))
		elseif dwelled(self, "weakSince", weak, now, self.lockDelay, "weak signal") then
			local reason = ("weak signal: est %.1f under %g for %gs"):format(
				self.estimate,
				self.lockThreshold,
				self.lockDelay
			)
			self:_transition("away", self.onAway, reason)
		end
	else
		local strong = fresh and self.estimate ~= nil and self.estimate > self.lockThreshold + self.returnHysteresis
		if dwelled(self, "strongSince", strong, now, self.returnDelay, "strong signal") then
			local reason = ("strong signal: est %.1f over %g for %gs"):format(
				self.estimate,
				self.lockThreshold + self.returnHysteresis,
				self.returnDelay
			)
			self:_transition("present", self.onReturn, reason)
		end
	end
end

-- The pipe protocol with the scanner app: one "<identifier>\t<rssi>\t<name>" line per
-- advertisement. Returns the identifier, RSSI (a number from -127 to 0) and name ("" if unnamed), or
-- nil for anything that is not a reading. Extra tabs stay in the name rather than shifting fields.
function M.parseReading(line)
	local id, rssi, name = line:match("^([^\t]+)\t(-?%d+)\t(.*)$")
	if not id then
		id, rssi = line:match("^([^\t]+)\t(-?%d+)$")
		name = ""
	end
	rssi = tonumber(rssi)
	if not id or rssi < -127 or rssi > 0 then return nil end
	return id, rssi, name
end

-- Splits streamed output into complete lines and the unfinished tail to prepend to the next chunk.
function M.splitLines(buffer)
	local lines = {}
	for line in buffer:gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	return lines, buffer:match("[^\n]*$")
end

-- The scanner's list-mode output as { id, name, rssi } entries, strongest first.
function M.parseDeviceList(text)
	local lines, rest = M.splitLines(text)
	if rest ~= "" then table.insert(lines, rest) end
	local devices = {}
	for _, line in ipairs(lines) do
		local id, rssi, name = M.parseReading(line)
		if id then table.insert(devices, { id = id, rssi = rssi, name = name }) end
	end
	table.sort(devices, function(a, b) return a.rssi > b.rssi end)
	return devices
end

-- Case-insensitive substring match of a configured needle against a device's identifier or name.
function M.matches(needle, id, name)
	if needle == "" then return false end
	needle = needle:lower()
	return id:lower():find(needle, 1, true) ~= nil or (name or ""):lower():find(needle, 1, true) ~= nil
end

local function isTracked(tracked, id, name)
	for _, entry in ipairs(tracked) do
		if M.matches(entry.needle, id, name) then return true end
	end
	return false
end

-- Rows for the device picker. `tracked` is a list of { needle, label }; `nearby` a list of
-- { id, name, rssi }, strongest first. Unnamed devices (mostly beacons) are hidden unless tracked,
-- and tracked devices that were not heard are kept so they can be removed.
function M.pickerChoices(tracked, nearby)
	local choices = {}
	for _, device in ipairs(nearby) do
		local isTrackedDevice = isTracked(tracked, device.id, device.name)
		if device.name ~= "" or isTrackedDevice then
			local title = device.name ~= "" and device.name or device.id
			table.insert(choices, {
				kind = "device",
				id = device.id,
				name = device.name,
				tracked = isTrackedDevice,
				text = (isTrackedDevice and "✓ " or "") .. title,
				subText = ("%d dBm · %s"):format(device.rssi, device.id),
			})
		end
	end
	for _, entry in ipairs(tracked) do
		local heard = false
		for _, device in ipairs(nearby) do
			if M.matches(entry.needle, device.id, device.name) then heard = true end
		end
		if not heard then
			table.insert(choices, {
				kind = "saved",
				needle = entry.needle,
				tracked = true,
				text = "✓ " .. entry.label,
				subText = "not nearby",
			})
		end
	end
	return choices
end

-- The tracked list after selecting a picker row: a tracked row is removed, any other is added by
-- identifier (stable per Mac, unlike a name). The given list is not modified.
function M.toggleDevice(tracked, choice)
	local result = {}
	for _, entry in ipairs(tracked) do
		local selected
		if choice.kind == "saved" then
			selected = entry.needle == choice.needle
		else
			selected = M.matches(entry.needle, choice.id, choice.name)
		end
		if not (choice.tracked and selected) then table.insert(result, entry) end
	end
	if not choice.tracked then
		local label = choice.name ~= "" and choice.name or choice.id
		table.insert(result, { needle = choice.id, label = label })
	end
	return result
end

-- Several devices, one decision, set by `lockWhen`: "any" (the default) locks as soon as one device
-- is judged away and re-arms once all are back; "all" locks only when every device is away and
-- re-arms as soon as one is back.
local Group = {}
Group.__index = Group

function M.newGroup(opts, devices, now)
	local group =
		setmetatable({ state = "present", devices = {}, onAway = opts.onAway, onReturn = opts.onReturn }, Group)
	group.settings = {}
	for key, value in pairs(M.defaults) do
		group.settings[key] = value
	end
	for key, value in pairs(opts) do
		group.settings[key] = value
	end
	assert(
		group.settings.lockWhen == "any" or group.settings.lockWhen == "all",
		'lockWhen must be "any" or "all", not ' .. tostring(group.settings.lockWhen)
	)
	group.lockWhen = group.settings.lockWhen
	for _, entry in ipairs(devices) do
		local needle = type(entry) == "table" and entry.needle or entry
		local device = { needle = needle, label = type(entry) == "table" and entry.label or needle }
		local engineOpts = {}
		for key, value in pairs(opts) do
			engineOpts[key] = value
		end
		engineOpts.log = opts.log and function(message) opts.log(device.label .. ": " .. message) end or nil
		engineOpts.onAway = function(reason) group:_deviceAway(device, reason) end
		engineOpts.onReturn = function(reason) group:_deviceBack(device, reason) end
		device.engine = M.new(engineOpts, now)
		table.insert(group.devices, device)
	end
	return group
end

function Group:_deviceAway(device, reason)
	device.lastReason = reason
	if self.state ~= "present" then return end
	if self.lockWhen == "all" then
		for _, other in ipairs(self.devices) do
			if other.engine.state ~= "away" then return end
		end
	end
	self.state = "away"
	if #self.devices > 1 then
		if self.lockWhen == "all" then
			local parts = {}
			for _, other in ipairs(self.devices) do
				table.insert(parts, ("%s (%s)"):format(other.label, other.lastReason))
			end
			reason = "all devices away: " .. table.concat(parts, "; ")
		else
			reason = ("%s away: %s"):format(device.label, reason)
		end
	end
	if self.onAway then self.onAway(reason) end
end

function Group:_deviceBack(device, reason)
	if self.state ~= "away" then return end
	if self.lockWhen == "any" then
		for _, other in ipairs(self.devices) do
			if other.engine.state ~= "present" then return end
		end
	end
	self.state = "present"
	if self.onReturn then self.onReturn(device.label .. ": " .. reason) end
end

-- Attributes a scanner reading to the first device it matches; false if none does. The second
-- result is true when it is that device's first reading since it was last reset.
function Group:feedReading(now, id, name, rssi)
	for _, device in ipairs(self.devices) do
		if M.matches(device.needle, id, name) then
			if name and name ~= "" then device.label = name end
			local first = device.engine.estimate == nil
			device.engine:feed(now, rssi)
			return true, first
		end
	end
	return false
end

function Group:tick(now)
	for _, device in ipairs(self.devices) do
		device.engine:tick(now)
	end
end

function Group:resetSilence(now)
	for _, device in ipairs(self.devices) do
		device.engine:resetSilence(now)
	end
end

function Group:rearm(now)
	self.state = "present"
	for _, device in ipairs(self.devices) do
		device.engine:rearm(now)
	end
end

function Group:lastSeen()
	local latest = 0
	for _, device in ipairs(self.devices) do
		latest = math.max(latest, device.engine.lastSeen)
	end
	return latest
end

function Group:status()
	if self.state == "away" then return "away" end
	local present, total = 0, 0
	for _, device in ipairs(self.devices) do
		if device.engine:status() == "present" then present = present + 1 end
		total = total + 1
	end
	if self.lockWhen == "all" then return present > 0 and "present" or "searching" end
	return present == total and "present" or "searching"
end

-- Menu lines: each device's signal, then the limits in force.
function Group:describe(now)
	local lines = {}
	for _, device in ipairs(self.devices) do
		table.insert(lines, ("%s: %s"):format(device.label, device.engine:signalText(now)))
	end
	local settings = self.settings
	if #self.devices > 1 then
		table.insert(
			lines,
			self.lockWhen == "all" and "Locks only when every device is away" or "Locks as soon as any device is away"
		)
	end
	table.insert(
		lines,
		("Locks under %g dBm for %gs, or after %gs of silence"):format(
			settings.lockThreshold,
			settings.lockDelay,
			settings.missTimeout
		)
	)
	table.insert(
		lines,
		("Back over %g dBm for %gs"):format(settings.lockThreshold + settings.returnHysteresis, settings.returnDelay)
	)
	return lines
end

return M
