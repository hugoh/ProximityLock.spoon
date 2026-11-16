-- Busted tests for the pipe protocol between the scanner app and the spoon. Every line starts with its
-- type: "R\t<identifier>\t<rssi>\t<name>" for a reading, "H\t<ads>\t<state>" for a heartbeat.
-- Anything else is dropped, so a device's name cannot pass for another kind of line.

local presence = require("presence")

describe("parseHeartbeat", function()
	it("reads the advertisement count and Bluetooth state", function()
		local ads, state = presence.parseHeartbeat("H\t12\t5")

		assert.are.equal(12, ads)
		assert.are.equal(5, state)
	end)

	it("accepts zero advertisements", function() assert.are.equal(0, (presence.parseHeartbeat("H\t0\t5"))) end)

	it("is not mistaken for a reading, and readings are not heartbeats", function()
		assert.is_nil(presence.parseReading("H\t0\t5"))
		assert.is_nil(presence.parseHeartbeat("R\tAAAA-1111\t-60\tPhone"))
		assert.is_nil(presence.parseHeartbeat(""))
	end)

	it("rejects the untagged formats and malformed counts", function()
		assert.is_nil(presence.parseHeartbeat("heartbeat ads=0 state=5"))
		assert.is_nil(presence.parseHeartbeat("H\tmany\t5"))
		assert.is_nil(presence.parseHeartbeat("H\t0\t5\textra"))
		assert.is_nil(presence.parseHeartbeat("H\t-1\t5"))
	end)
end)

describe("parseReading", function()
	it("ignores blank lines", function() assert.is_nil(presence.parseReading("")) end)

	it("reads the identifier, RSSI and name", function()
		local id, rssi, name = presence.parseReading("R\tAAAA-1111\t-60\tAlex’s iPhone")

		assert.are.equal("AAAA-1111", id)
		assert.are.equal(-60, rssi)
		assert.are.equal("Alex’s iPhone", name)
	end)

	it("returns the RSSI as a number", function()
		local _, rssi = presence.parseReading("R\tAAAA-1111\t-60\tx")

		assert.are.equal("number", type(rssi))
	end)

	it("accepts an unnamed device, with or without the trailing tab", function()
		local _, _, withTab = presence.parseReading("R\tAAAA-1111\t-60\t")
		local _, _, withoutTab = presence.parseReading("R\tAAAA-1111\t-60")

		assert.are.equal("", withTab)
		assert.are.equal("", withoutTab)
	end)

	it("keeps extra tabs in the name rather than shifting the fields", function()
		local id, rssi, name = presence.parseReading("R\tAAAA-1111\t-60\tone\t-30\ttwo")

		assert.are.equal("AAAA-1111", id)
		assert.are.equal(-60, rssi)
		assert.are.equal("one\t-30\ttwo", name)
	end)

	it("rejects lines that are not readings", function()
		assert.is_nil((presence.parseReading("")))
		assert.is_nil((presence.parseReading("no tabs here")))
		assert.is_nil((presence.parseReading("R\tAAAA-1111\tloud\tx")))
		assert.is_nil((presence.parseReading("R\t\t-60\tx")))
	end)

	it("rejects the untagged format and unknown tags", function()
		assert.is_nil((presence.parseReading("AAAA-1111\t-60\tx")))
		assert.is_nil((presence.parseReading("X\tAAAA-1111\t-60\tx")))
		assert.is_nil((presence.parseReading("r\tAAAA-1111\t-60\tx")))
		assert.is_nil((presence.parseReading("heartbeat\t-50\tx")))
	end)

	it("rejects an RSSI outside what a radio can report", function()
		assert.is_nil((presence.parseReading("R\tAAAA-1111\t50\tx")))
		assert.is_nil((presence.parseReading("R\tAAAA-1111\t-200\tx")))
		assert.is_nil((presence.parseReading("R\tAAAA-1111\t127\tx")))
	end)

	it("treats a name that imitates another line as just a name", function()
		for _, name in ipairs({ "Scanner heartbeat", "H\t0\t5", "heartbeat ads=0 state=5", "R\tOTHER\t-10\tx" }) do
			local id, rssi, parsed = presence.parseReading("R\tAAAA-1111\t-60\t" .. name)

			assert.are.equal("AAAA-1111", id)
			assert.are.equal(-60, rssi)
			assert.are.equal(name, parsed)
			assert.is_nil(presence.parseHeartbeat("R\tAAAA-1111\t-60\t" .. name))
		end
	end)

	it("cuts an overlong name and rejects an overlong identifier", function()
		local _, _, name = presence.parseReading("R\tAAAA-1111\t-60\t" .. ("x"):rep(500))

		assert.are.equal(128, #name)
		assert.is_nil((presence.parseReading("R\t" .. ("A"):rep(65) .. "\t-60\tx")))
	end)
end)

describe("splitLines", function()
	it("returns complete lines and keeps the unfinished tail", function()
		local lines, rest = presence.splitLines("one\ntwo\nta")

		assert.are.same({ "one", "two" }, lines)
		assert.are.equal("ta", rest)
	end)

	it("has no lines and an empty tail for an empty buffer", function()
		local lines, rest = presence.splitLines("")

		assert.are.same({}, lines)
		assert.are.equal("", rest)
	end)

	it("reassembles a line split across chunks", function()
		local _, rest = presence.splitLines("R\tAAAA-1111\t-6")
		local lines, remaining = presence.splitLines(rest .. "0\tx\nBBBB")

		assert.are.same({ "R\tAAAA-1111\t-60\tx" }, lines)
		assert.are.equal("BBBB", remaining)
	end)

	it("treats a trailing newline as a finished line with nothing left over", function()
		local lines, rest = presence.splitLines("one\n")

		assert.are.same({ "one" }, lines)
		assert.are.equal("", rest)
	end)
end)

describe("parseDeviceList", function()
	it("returns the devices strongest first", function()
		local devices = presence.parseDeviceList("R\tA-1\t-70\tWatch\nR\tB-2\t-45\tPhone\nR\tC-3\t-60\t\n")

		assert.are.equal(3, #devices)
		assert.are.same({ id = "B-2", rssi = -45, name = "Phone" }, devices[1])
		assert.are.same({ id = "C-3", rssi = -60, name = "" }, devices[2])
		assert.are.same({ id = "A-1", rssi = -70, name = "Watch" }, devices[3])
	end)

	it("skips malformed lines", function()
		local devices =
			presence.parseDeviceList("garbage\nR\tA-1\t-70\tWatch\n\nR\tB-2\toops\tx\nB-2\t-50\tOld format\n")

		assert.are.equal(1, #devices)
		assert.are.equal("A-1", devices[1].id)
	end)

	it("includes a last line that has no newline", function()
		local devices = presence.parseDeviceList("R\tA-1\t-70\tWatch\nR\tB-2\t-45\tPhone")

		assert.are.equal(2, #devices)
	end)

	it("is empty for no output", function() assert.are.same({}, presence.parseDeviceList("")) end)
end)
