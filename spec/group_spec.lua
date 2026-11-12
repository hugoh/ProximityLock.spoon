-- Busted tests for tracking several devices: attribution, any-device-near semantics, status, menu text.

local presence = require("presence")

local group, events, logs

local function newGroup(devices, opts)
	events = { away = 0, back = 0 }
	logs = {}
	opts = opts or {}
	opts.log = function(message) table.insert(logs, message) end
	opts.onAway = function(reason)
		events.away = events.away + 1
		events.reason = reason
	end
	opts.onReturn = function() events.back = events.back + 1 end
	group = presence.newGroup(opts, devices, 0)
end

-- Feeds each reading ({ name =, rssi = }) once a second over [from, to), ticking after each step.
local function step(from, to, readings)
	for t = from, to - 1 do
		for _, reading in ipairs(readings) do
			group:feedReading(t, "id-" .. reading.name, reading.name, reading.rssi)
		end
		group:tick(t)
	end
end

describe("matches", function()
	it("finds the needle in the name or identifier, ignoring case", function()
		assert.is_true(presence.matches("phone", "AAAA-1", "My Phone"))
		assert.is_true(presence.matches("aaaa", "AAAA-1", "Other"))
	end)

	it("does not match unrelated devices or an empty needle", function()
		assert.is_false(presence.matches("watch", "AAAA-1", "My Phone"))
		assert.is_false(presence.matches("", "AAAA-1", "My Phone"))
	end)
end)

describe("attribution", function()
	it("feeds only the device whose needle matches", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })

		assert.is_true(group:feedReading(0, "id-1", "My Phone", -60))
		assert.is_false(group:feedReading(0, "id-2", "Speaker", -40))
		assert.are.equal(-60, group.devices[1].engine.estimate)
		assert.is_nil(group.devices[2].engine.estimate)
	end)

	it("says whether a reading is the first one heard from that device", function()
		newGroup({ "Phone" })

		local _, first = group:feedReading(0, "id-1", "Phone", -60)
		local _, second = group:feedReading(1, "id-1", "Phone", -61)

		assert.is_true(first)
		assert.is_false(second)
	end)

	it("labels a device with the name it advertises", function()
		newGroup({ "AAAA1111" })

		group:feedReading(0, "AAAA1111-2782", "Alex’s iPhone", -60)

		assert.are.equal("Alex’s iPhone", group.devices[1].label)
	end)

	it("starts from a given label", function()
		newGroup({ { needle = "AAAA1111", label = "Alex’s iPhone" } })

		assert.are.equal("Alex’s iPhone", group.devices[1].label)
	end)
end)

describe("locking with several devices", function()
	it("locks when its only device goes away, with that device's reason", function()
		newGroup({ "Phone" })

		step(0, 20, { { name = "Phone", rssi = -60 } })
		step(20, 60, { { name = "Phone", rssi = -95 } })

		assert.are.equal(1, events.away)
		assert.is_true(events.reason:find("weak signal") ~= nil)
	end)

	it("does not lock while another device is still near", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })
		step(0, 20, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })

		step(20, 80, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })

		assert.are.equal(0, events.away)
		assert.are.equal("present", group:status())
	end)

	it("locks once the last near device goes away, naming every device", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })
		step(0, 20, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })
		step(20, 60, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })

		step(60, 100, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -95 } })

		assert.are.equal(1, events.away)
		assert.is_true(events.reason:find("Phone") ~= nil and events.reason:find("Watch") ~= nil)
		assert.are.equal("away", group:status())
	end)

	it("treats a device that is never seen as away", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all", missTimeout = 30 })

		step(0, 60, { { name = "Phone", rssi = -95 } })

		assert.are.equal(1, events.away)
	end)

	it("returns when any one device comes back", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })
		step(0, 20, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })
		step(20, 100, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -95 } })

		step(100, 120, { { name = "Watch", rssi = -55 } })

		assert.are.equal(1, events.back)
		assert.are.equal("present", group:status())
	end)
end)

describe("status", function()
	it("is searching before any reading arrives", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })

		assert.are.equal("searching", group:status())
	end)

	it("is present once any device has been heard", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })

		group:feedReading(0, "id-1", "Phone", -60)

		assert.are.equal("present", group:status())
	end)
end)

describe("rearm", function()
	it("restarts the assessment of every device after a lock", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })
		step(0, 20, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })
		step(20, 60, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })
		assert.are.equal("away", group:status())

		group:rearm(100)

		assert.are.equal("searching", group:status())
		assert.are.equal(1, events.away)
	end)

	it("locks again if a device is still weak afterwards", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })
		step(0, 20, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })
		step(20, 60, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })
		group:rearm(100)

		step(100, 160, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })

		assert.are.equal(2, events.away)
	end)

	it("does not lock again if every device is back near", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })
		step(0, 20, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })
		step(20, 60, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })
		group:rearm(100)

		step(100, 200, { { name = "Phone", rssi = -55 }, { name = "Watch", rssi = -55 } })

		assert.are.equal(1, events.away)
		assert.are.equal("present", group:status())
	end)
end)

describe("silence", function()
	it("reports the latest reading across devices", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })
		group:feedReading(5, "id-1", "Phone", -60)
		group:feedReading(9, "id-2", "Watch", -60)

		assert.are.equal(9, group:lastSeen())
	end)

	it("resets every device", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })
		step(0, 10, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } })

		group:resetSilence(100)

		assert.are.equal("searching", group:status())
		assert.are.equal(100, group:lastSeen())
	end)
end)

describe("describe", function()
	it("lists each device's signal, then the limits", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "all" })
		group:feedReading(0.4, "id-1", "Phone", -60)

		local lines = group:describe(5.7)

		assert.are.equal("Phone: ≈-60 dBm, seen 5s ago", lines[1])
		assert.are.equal("Watch: searching", lines[2])
		assert.are.equal("Locks only when every device is away", lines[3])
		assert.are.equal("Locks under -75 dBm for 10s, or after 60s of silence", lines[4])
		assert.are.equal("Back over -67 dBm for 3s", lines[5])
	end)

	it("omits the every-device line for a single device", function()
		newGroup({ "Phone" })

		local lines = group:describe(1)

		assert.are.equal("Phone: searching", lines[1])
		assert.are.equal("Locks under -75 dBm for 10s, or after 60s of silence", lines[2])
	end)

	it("prefixes a device's debug log lines with its label", function()
		newGroup({ "Phone" })

		group:feedReading(0, "id-1", "Phone", -60)

		assert.is_true(logs[1]:find("^Phone: sample rssi=%-60") ~= nil)
	end)
end)

describe("locking when any device is away (the default)", function()
	local function bothNear(from, to) step(from, to, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -60 } }) end

	it("is the default", function()
		newGroup({ "Phone", "Watch" })
		bothNear(0, 20)

		step(20, 60, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -60 } })

		assert.are.equal(1, events.away)
	end)

	it("does not lock while every device is near", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })

		bothNear(0, 80)

		assert.are.equal(0, events.away)
		assert.are.equal("present", group:status())
	end)

	it("locks as soon as one device is away, naming it", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })
		bothNear(0, 20)

		step(20, 60, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -95 } })

		assert.are.equal(1, events.away)
		assert.is_true(events.reason:find("Watch") ~= nil)
		assert.are.equal("away", group:status())
	end)

	it("locks once, not again when the other device also leaves", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })
		bothNear(0, 20)
		step(20, 60, { { name = "Phone", rssi = -60 }, { name = "Watch", rssi = -95 } })

		step(60, 100, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -95 } })

		assert.are.equal(1, events.away)
	end)

	it("stays away until every device is back", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })
		bothNear(0, 20)
		step(20, 100, { { name = "Phone", rssi = -95 }, { name = "Watch", rssi = -95 } })

		step(100, 130, { { name = "Watch", rssi = -55 } })
		assert.are.equal(0, events.back)
		assert.are.equal("away", group:status())

		step(130, 150, { { name = "Phone", rssi = -55 }, { name = "Watch", rssi = -55 } })
		assert.are.equal(1, events.back)
		assert.are.equal("present", group:status())
	end)

	it("locks when a device is never heard, once it has been silent for missTimeout", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any", missTimeout = 30 })

		step(0, 40, { { name = "Phone", rssi = -60 } })

		assert.are.equal(1, events.away)
	end)

	it("is searching, not present, while a device has not been heard yet", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })

		group:feedReading(0, "id-1", "Phone", -60)

		assert.are.equal("searching", group:status())
	end)

	it("describes the rule in the menu", function()
		newGroup({ "Phone", "Watch" }, { lockWhen = "any" })

		local lines = group:describe(1)

		assert.are.equal("Locks as soon as any device is away", lines[3])
	end)

	it(
		"rejects an unknown value",
		function() assert.is_false((pcall(presence.newGroup, { lockWhen = "some" }, { "Phone" }, 0))) end
	)
end)
