-- Busted tests for the pipe protocol between the scanner app and the spoon:
-- one "<identifier>\t<rssi>\t<name>" line per advertisement.

local presence = require("presence")

describe("parseReading", function()
	it("ignores the scanner's blank heartbeat lines", function() assert.is_nil(presence.parseReading("")) end)

	it("reads the identifier, RSSI and name", function()
		local id, rssi, name = presence.parseReading("AAAA-1111\t-60\tAlex’s iPhone")

		assert.are.equal("AAAA-1111", id)
		assert.are.equal(-60, rssi)
		assert.are.equal("Alex’s iPhone", name)
	end)

	it("returns the RSSI as a number", function()
		local _, rssi = presence.parseReading("AAAA-1111\t-60\tx")

		assert.are.equal("number", type(rssi))
	end)

	it("accepts an unnamed device, with or without the trailing tab", function()
		local _, _, withTab = presence.parseReading("AAAA-1111\t-60\t")
		local _, _, withoutTab = presence.parseReading("AAAA-1111\t-60")

		assert.are.equal("", withTab)
		assert.are.equal("", withoutTab)
	end)

	it("keeps extra tabs in the name rather than shifting the fields", function()
		local id, rssi, name = presence.parseReading("AAAA-1111\t-60\tone\t-30\ttwo")

		assert.are.equal("AAAA-1111", id)
		assert.are.equal(-60, rssi)
		assert.are.equal("one\t-30\ttwo", name)
	end)

	it("rejects lines that are not readings", function()
		assert.is_nil((presence.parseReading("")))
		assert.is_nil((presence.parseReading("no tabs here")))
		assert.is_nil((presence.parseReading("AAAA-1111\tloud\tx")))
		assert.is_nil((presence.parseReading("\t-60\tx")))
	end)

	it("rejects an RSSI outside what a radio can report", function()
		assert.is_nil((presence.parseReading("AAAA-1111\t50\tx")))
		assert.is_nil((presence.parseReading("AAAA-1111\t-200\tx")))
		assert.is_nil((presence.parseReading("AAAA-1111\t127\tx")))
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
		local _, rest = presence.splitLines("AAAA-1111\t-6")
		local lines, remaining = presence.splitLines(rest .. "0\tx\nBBBB")

		assert.are.same({ "AAAA-1111\t-60\tx" }, lines)
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
		local devices = presence.parseDeviceList("A-1\t-70\tWatch\nB-2\t-45\tPhone\nC-3\t-60\t\n")

		assert.are.equal(3, #devices)
		assert.are.same({ id = "B-2", rssi = -45, name = "Phone" }, devices[1])
		assert.are.same({ id = "C-3", rssi = -60, name = "" }, devices[2])
		assert.are.same({ id = "A-1", rssi = -70, name = "Watch" }, devices[3])
	end)

	it("skips malformed lines", function()
		local devices = presence.parseDeviceList("garbage\nA-1\t-70\tWatch\n\nB-2\toops\tx\n")

		assert.are.equal(1, #devices)
		assert.are.equal("A-1", devices[1].id)
	end)

	it("includes a last line that has no newline", function()
		local devices = presence.parseDeviceList("A-1\t-70\tWatch\nB-2\t-45\tPhone")

		assert.are.equal(2, #devices)
	end)

	it("is empty for no output", function() assert.are.same({}, presence.parseDeviceList("")) end)
end)
