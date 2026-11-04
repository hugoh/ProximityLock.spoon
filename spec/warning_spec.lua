-- Busted tests for the countdown before a lock, with a stubbed `hs` so the timer, the Esc hotkey and
-- the on-screen notice can be driven by hand.

local attach = require("warning")

local h, obj

-- WCAG relative luminance and contrast ratio, for colors given as { red, green, blue } or { white }.
local function luminance(color)
	local function linear(channel) return channel <= 0.03928 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4 end
	local red, green, blue = color.red or color.white, color.green or color.white, color.blue or color.white
	return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
end

local function contrast(a, b)
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

local function setup(opts)
	opts = opts or {}
	h = {
		timers = {},
		hotkeys = {},
		notices = {},
		styles = {},
		errors = {},
		rearmed = {},
		closed = {},
		logs = {},
		locks = 0,
		screenLocked = false,
		status = "away",
	}
	_G.hs = {
		timer = {
			secondsSinceEpoch = function() return 42 end,
			doEvery = function(_, fn)
				local timer = { fn = fn, stopped = false }
				function timer:stop() self.stopped = true end
				table.insert(h.timers, timer)
				return timer
			end,
		},
		hotkey = {
			new = function(_, key, fn)
				local hotkey = { key = key, fn = fn, enabled = false, deleted = false }
				function hotkey:enable()
					self.enabled = true
					return self
				end
				function hotkey:delete() self.deleted = true end
				table.insert(h.hotkeys, hotkey)
				return hotkey
			end,
		},
		alert = { closeSpecific = function(id) h.closed[id] = true end },
		caffeinate = { sessionProperties = function() return { CGSSessionScreenIsLocked = h.screenLocked } end },
	}
	obj = {
		lockWarning = opts.lockWarning or 3,
		log = {
			i = function(message) table.insert(h.logs, message) end,
			e = function(message) table.insert(h.errors, message) end,
		},
		onAway = function() h.locks = h.locks + 1 end,
		_engine = {
			status = function() return h.status end,
			rearm = function(_, now) table.insert(h.rearmed, now) end,
		},
		_notify = function(_, message, _, style)
			table.insert(h.notices, message)
			table.insert(h.styles, style)
			return #h.notices
		end,
	}
	attach(obj)
end

local function tick(times)
	for _ = 1, times do
		h.timers[#h.timers].fn()
	end
end

describe("lock warning", function()
	it("does not lock straight away", function()
		setup()

		obj:_lockWithWarning()

		assert.are.equal(0, h.locks)
	end)

	it("locks once the countdown ends", function()
		setup()
		obj:_lockWithWarning()

		tick(3)

		assert.are.equal(1, h.locks)
	end)

	it("counts down in the notice and says how to cancel", function()
		setup()
		obj:_lockWithWarning()

		tick(2)

		assert.are.equal("ProximityLock: locking in 3… (Esc to cancel)", h.notices[1])
		assert.are.equal("ProximityLock: locking in 2… (Esc to cancel)", h.notices[2])
		assert.are.equal("ProximityLock: locking in 1… (Esc to cancel)", h.notices[3])
	end)

	it("shows the countdown on a red background", function()
		setup()

		obj:_lockWithWarning()
		tick(1)

		for _, style in ipairs(h.styles) do
			assert.is_true(style.fillColor.red > style.fillColor.green and style.fillColor.red > style.fillColor.blue)
		end
		assert.are.equal(2, #h.styles)
	end)

	it("keeps the text readable on the red: opaque fill, explicit text color, 7:1 contrast", function()
		setup()

		obj:_lockWithWarning()

		local style = h.styles[1]
		assert.are.equal(1, style.fillColor.alpha)
		assert.is_not_nil(style.textColor)
		assert.is_true(contrast(style.fillColor, style.textColor) >= 7)
	end)

	it("takes Esc only while counting down", function()
		setup()
		obj:_lockWithWarning()

		assert.is_true(h.hotkeys[1].enabled)
		assert.are.equal("escape", h.hotkeys[1].key)

		tick(3)
		assert.is_true(h.hotkeys[1].deleted)
	end)

	it("does not lock if cancelled with Esc", function()
		setup()
		obj:_lockWithWarning()
		tick(1)

		h.hotkeys[1].fn()
		tick(0)

		assert.are.equal(0, h.locks)
		assert.is_true(h.timers[1].stopped)
		assert.is_true(h.hotkeys[1].deleted)
	end)

	it("reports whether there was anything to cancel", function()
		setup()

		assert.is_false(obj:cancelLock())

		obj:_lockWithWarning()
		assert.is_true(obj:cancelLock())
	end)

	it("starts the assessment over when cancelled", function()
		setup()
		obj:_lockWithWarning()

		obj:cancelLock()

		assert.are.same({ 42 }, h.rearmed)
	end)

	it("does not start over when the spoon is stopped mid-countdown", function()
		setup()
		obj:_lockWithWarning()

		obj:_endWarning()

		assert.are.same({}, h.rearmed)
	end)

	it("closes its notice when cancelled", function()
		setup()
		obj:_lockWithWarning()

		obj:cancelLock()

		assert.is_true(h.closed[1])
	end)

	it("does not lock if the devices are no longer away at the end", function()
		setup()
		obj:_lockWithWarning()
		tick(1)

		h.status = "present"
		tick(2)

		assert.are.equal(0, h.locks)
	end)

	it("locks immediately when the warning is turned off", function()
		setup({ lockWarning = 0 })

		obj:_lockWithWarning()

		assert.are.equal(1, h.locks)
		assert.are.equal(0, #h.timers)
	end)

	it("locks immediately when the screen is already locked", function()
		setup()
		h.screenLocked = true

		obj:_lockWithWarning()

		assert.are.equal(1, h.locks)
		assert.are.equal(0, #h.timers)
	end)

	it("does not start a second countdown while one is running", function()
		setup()
		obj:_lockWithWarning()

		obj:_lockWithWarning()

		assert.are.equal(1, #h.timers)
	end)

	it("can warn again after a cancelled countdown", function()
		setup()
		obj:_lockWithWarning()
		obj:cancelLock()

		obj:_lockWithWarning()
		tick(3)

		assert.are.equal(1, h.locks)
	end)

	it("cleans up and frees Esc if locking throws", function()
		setup()
		obj.onAway = function() error("boom") end
		obj:_lockWithWarning()

		assert.is_true((pcall(tick, 3)))

		assert.is_nil(obj._warning)
		assert.is_true(h.hotkeys[1].deleted)
		assert.are.equal(1, #h.errors)
	end)

	it("copes with a fractional warning time", function()
		setup({ lockWarning = 2.5 })
		obj:_lockWithWarning()

		tick(3)

		assert.are.equal(1, h.locks)
		assert.are.equal("ProximityLock: locking in 3… (Esc to cancel)", h.notices[1])
	end)
end)

describe("lock warning failures", function()
	it("locks anyway and frees Esc if the notice cannot be shown", function()
		setup()
		obj._notify = function() error("no screen") end

		assert.is_true((pcall(obj._lockWithWarning, obj)))

		assert.is_nil(obj._warning)
		assert.is_true(h.hotkeys[1].deleted)
		assert.are.equal(1, h.locks)
		assert.are.equal(1, #h.errors)
	end)

	it("lets a later lock through after a failed one", function()
		setup()
		obj._notify = function() error("no screen") end
		obj:_lockWithWarning()

		obj:_lockWithWarning()

		assert.are.equal(2, h.locks)
	end)

	it("reassesses from scratch when the lock fails, so it is tried again", function()
		setup({ lockWarning = 0 })
		obj.onAway = function() error("boom") end

		assert.is_true((pcall(obj._lockWithWarning, obj)))

		assert.are.same({ 42 }, h.rearmed)
		assert.are.equal(1, #h.errors)
	end)

	it("does the same when the lock fails at the end of the countdown", function()
		setup()
		obj.onAway = function() error("boom") end
		obj:_lockWithWarning()

		tick(3)

		assert.are.same({ 42 }, h.rearmed)
	end)
end)
