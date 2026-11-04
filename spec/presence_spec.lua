-- Busted tests for the presence engine: Kalman smoothing plus dwell/hysteresis decisions.

local presence = require("presence")

local engine, events, logs

local function newEngine(opts)
	events = { away = 0, back = 0 }
	logs = {}
	opts = opts or {}
	opts.log = function(message) table.insert(logs, message) end
	opts.onAway = function(reason)
		events.away = events.away + 1
		events.reason = reason
	end
	opts.onReturn = function() events.back = events.back + 1 end
	engine = presence.new(opts, 0)
end

-- Feeds `rssi` every second over [from, to), ticking after each sample.
local function hold(from, to, rssi)
	for t = from, to - 1 do
		engine:feed(t, rssi)
		engine:tick(t)
	end
end

-- Ticks every second over [from, to) with no samples at all.
local function silence(from, to)
	for t = from, to - 1 do
		engine:tick(t)
	end
end

describe("kalman smoothing", function()
	it("adopts the first sample as the estimate", function()
		newEngine()

		engine:feed(0, -55)

		assert.are.equal(-55, engine.estimate)
	end)

	it("barely moves for a single spike", function()
		newEngine()
		hold(0, 20, -60)

		engine:feed(20, -95)

		assert.is_true(engine.estimate > -70)
	end)

	it("trusts a sample more after a long gap", function()
		newEngine()
		hold(0, 20, -60)
		engine:feed(21, -80)
		local shortGap = engine.estimate

		newEngine()
		hold(0, 20, -60)
		engine:feed(60, -80)

		assert.is_true(engine.estimate < shortGap)
	end)

	it("counts a duplicate report of one advertisement once", function()
		newEngine()
		hold(0, 20, -60)
		engine:feed(20, -80)
		local once = engine.estimate

		newEngine()
		hold(0, 20, -60)
		engine:feed(20, -80)
		engine:feed(20, -80)

		assert.are.equal(once, engine.estimate)
	end)
end)

local function logged(pattern)
	for _, message in ipairs(logs) do
		if message:find(pattern) then return true end
	end
	return false
end

describe("logging", function()
	it("logs each sample with the raw and smoothed values", function()
		newEngine()

		engine:feed(0, -60)

		assert.is_true(logged("rssi=%-60 est=%-60%.0"))
	end)

	it("gives a weak-signal reason when it locks", function()
		newEngine()
		hold(0, 20, -60)
		hold(20, 60, -95)

		assert.is_true(events.reason:find("weak signal") ~= nil)
	end)

	it("gives a silence reason when it locks", function()
		newEngine({ missTimeout = 30 })
		hold(0, 10, -60)
		silence(10, 40)

		assert.is_true(events.reason:find("no sample for 30s") ~= nil)
	end)

	it("logs when a weak dip begins and when it ends", function()
		newEngine({ lockDelay = 10 })
		hold(0, 20, -60)
		hold(20, 28, -90)
		hold(28, 40, -60)

		assert.is_true(logged("weak signal began"))
		assert.is_true(logged("weak signal ended"))
	end)

	it("logs how long the device has been silent", function()
		newEngine({ missTimeout = 30 })
		hold(0, 10, -60)
		silence(10, 20)

		assert.is_true(logged("no sample for 10s"))
	end)
end)

describe("resetSilence", function()
	it("restarts the missTimeout clock", function()
		newEngine({ missTimeout = 30 })
		hold(0, 10, -60)

		engine:resetSilence(100)
		silence(100, 129)
		assert.are.equal(0, events.away)

		silence(129, 131)
		assert.are.equal(1, events.away)
	end)

	it("reports searching until a fresh sample arrives", function()
		newEngine()
		hold(0, 10, -60)

		engine:resetSilence(100)

		assert.are.equal("searching", engine:status())
	end)

	it("does not let a stale estimate bring the device back from away", function()
		newEngine()
		hold(0, 20, -60)
		hold(20, 60, -95)
		assert.are.equal("away", engine:status())

		engine:resetSilence(100)
		silence(100, 120)

		assert.are.equal(0, events.back)
		assert.are.equal("away", engine:status())
	end)

	it("returns once fresh strong samples arrive after the reset", function()
		newEngine()
		hold(0, 20, -60)
		hold(20, 60, -95)

		engine:resetSilence(100)
		hold(100, 120, -55)

		assert.are.equal(1, events.back)
	end)
end)

describe("rearm", function()
	local function goAway()
		newEngine({ missTimeout = 30 })
		hold(0, 20, -60)
		hold(20, 60, -95)
		assert.are.equal("away", engine:status())
	end

	it("returns an away device to searching with no estimate", function()
		goAway()

		engine:rearm(100)

		assert.are.equal("searching", engine:status())
		assert.is_nil(engine.estimate)
	end)

	it("can go away again if the device is still gone", function()
		goAway()
		engine:rearm(100)

		silence(100, 131)

		assert.are.equal(2, events.away)
	end)

	it("stays present when the device is back and strong", function()
		goAway()
		engine:rearm(100)

		hold(100, 160, -55)

		assert.are.equal(1, events.away)
		assert.are.equal("present", engine:status())
	end)

	it("does not report the device as back", function()
		goAway()

		engine:rearm(100)

		assert.are.equal(0, events.back)
	end)
end)

describe("status", function()
	it("is searching until the first sample arrives", function()
		newEngine()

		assert.are.equal("searching", engine:status())
	end)

	it("is present once a sample arrives", function()
		newEngine()

		engine:feed(0, -55)

		assert.are.equal("present", engine:status())
	end)

	it("is away after the engine locks", function()
		newEngine()
		hold(0, 20, -60)
		hold(20, 60, -95)

		assert.are.equal("away", engine:status())
	end)
end)

describe("fractional timestamps", function()
	-- hs.timer.secondsSinceEpoch() is fractional, unlike the whole seconds used elsewhere here.
	local function holdAt(from, to, rssi, offset)
		for t = from, to - 1 do
			engine:feed(t + offset, rssi)
			engine:tick(t + offset + 0.3)
		end
	end

	it("locks on silence without erroring", function()
		newEngine({ missTimeout = 30 })
		holdAt(0, 10, -60, 0.4)

		for t = 10, 45 do
			assert.is_true((pcall(engine.tick, engine, t + 0.7)))
		end

		assert.are.equal(1, events.away)
	end)

	it("locks on a weak signal and returns without erroring", function()
		newEngine()
		holdAt(0, 20, -60, 0.4)
		holdAt(20, 60, -95, 0.4)
		holdAt(60, 90, -55, 0.4)

		assert.are.equal(1, events.away)
		assert.are.equal(1, events.back)
	end)
end)

describe("going away", function()
	it("defaults to locking under -75 dBm", function()
		newEngine()
		hold(0, 20, -60)

		hold(20, 60, -78)

		assert.are.equal(1, events.away)
	end)

	it("fires once when the signal stays weak past lockDelay", function()
		newEngine()
		hold(0, 20, -60)

		hold(20, 60, -90)

		assert.are.equal(1, events.away)
		assert.are.equal("away", engine.state)
	end)

	it("ignores a weak dip shorter than lockDelay", function()
		newEngine({ lockDelay = 10 })
		hold(0, 20, -60)

		hold(20, 28, -90)
		hold(28, 60, -60)

		assert.are.equal(0, events.away)
	end)

	it("fires when no sample arrives for missTimeout", function()
		newEngine({ missTimeout = 30 })
		hold(0, 10, -60)

		silence(10, 39)
		assert.are.equal(0, events.away)

		silence(39, 40)
		assert.are.equal(1, events.away)
	end)

	it("tolerates a gap shorter than missTimeout", function()
		newEngine({ missTimeout = 30 })
		hold(0, 10, -60)

		silence(10, 35)
		hold(35, 60, -60)

		assert.are.equal(0, events.away)
	end)
end)

describe("coming back", function()
	local function goAway()
		newEngine()
		hold(0, 20, -60)
		hold(20, 60, -95)
	end

	it("stays away while the signal sits between the lock and return thresholds", function()
		goAway()

		hold(60, 120, -70)

		assert.are.equal(0, events.back)
		assert.are.equal("away", engine.state)
	end)

	it("returns once the signal is strong past returnDelay", function()
		goAway()

		hold(60, 120, -55)

		assert.are.equal(1, events.back)
		assert.are.equal("present", engine.state)
	end)

	it("does not return on a brief strong burst", function()
		newEngine({ returnDelay = 10 })
		hold(0, 20, -60)
		hold(20, 60, -95)

		hold(60, 63, -40)
		hold(63, 120, -95)

		assert.are.equal(0, events.back)
	end)

	it("can lock again after returning", function()
		goAway()
		hold(60, 120, -55)

		hold(120, 200, -95)

		assert.are.equal(2, events.away)
	end)
end)
