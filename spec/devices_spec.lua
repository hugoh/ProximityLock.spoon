-- Busted tests for the device picker's choices and what selecting one does to the tracked list.

local presence = require("presence")

local PHONE = { id = "AAAA-1111", name = "Alex’s iPhone", rssi = -50 }
local WATCH = { id = "BBBB-2222", name = "Alex’s Watch", rssi = -60 }
local BEACON = { id = "CCCC-3333", name = "", rssi = -40 }

describe("pickerChoices", function()
	it("lists named nearby devices, strongest first, and hides unnamed ones", function()
		local choices = presence.pickerChoices({}, { BEACON, PHONE, WATCH })

		assert.are.equal(2, #choices)
		assert.are.equal("Alex’s iPhone", choices[1].text)
		assert.are.equal("Alex’s Watch", choices[2].text)
	end)

	it("describes a device with its signal and identifier", function()
		local choices = presence.pickerChoices({}, { PHONE })

		assert.are.equal("-50 dBm · AAAA-1111", choices[1].subText)
	end)

	it("marks devices that are already tracked", function()
		local choices = presence.pickerChoices({ { needle = "iphone", label = "iphone" } }, { PHONE, WATCH })

		assert.is_true(choices[1].tracked)
		assert.are.equal("✓ Alex’s iPhone", choices[1].text)
		assert.is_false(choices[2].tracked)
	end)

	it("shows a tracked device that is not nearby", function()
		local choices = presence.pickerChoices({ { needle = "OLD-ID", label = "Old tablet" } }, { PHONE })

		assert.are.equal(2, #choices)
		assert.are.equal("✓ Old tablet", choices[2].text)
		assert.are.equal("not nearby", choices[2].subText)
	end)

	it("shows an unnamed device when it is tracked", function()
		local choices = presence.pickerChoices({ { needle = "CCCC-3333", label = "CCCC-3333" } }, { BEACON })

		assert.are.equal(1, #choices)
		assert.are.equal("✓ CCCC-3333", choices[1].text)
	end)
end)

describe("toggleDevice", function()
	it("adds a device by identifier, labelled with its name", function()
		local choice = presence.pickerChoices({}, { PHONE })[1]

		local tracked = presence.toggleDevice({}, choice)

		assert.are.same({ { needle = "AAAA-1111", label = "Alex’s iPhone" } }, tracked)
	end)

	it("labels an unnamed device with its identifier", function()
		local unchecked = { kind = "device", id = BEACON.id, name = "", tracked = false }

		local tracked = presence.toggleDevice({}, unchecked)

		assert.are.same({ { needle = "CCCC-3333", label = "CCCC-3333" } }, tracked)
	end)

	it("removes a tracked device that matches by a name needle", function()
		local list = { { needle = "iphone", label = "iphone" }, { needle = "BBBB-2222", label = "Alex’s Watch" } }
		local choice = presence.pickerChoices(list, { PHONE, WATCH })[1]

		local tracked = presence.toggleDevice(list, choice)

		assert.are.same({ { needle = "BBBB-2222", label = "Alex’s Watch" } }, tracked)
	end)

	it("removes a tracked device that is not nearby", function()
		local list = { { needle = "OLD-ID", label = "Old tablet" } }
		local choice = presence.pickerChoices(list, {})[1]

		local tracked = presence.toggleDevice(list, choice)

		assert.are.same({}, tracked)
	end)

	it("does not change the list it was given", function()
		local list = { { needle = "OLD-ID", label = "Old tablet" } }
		local choice = presence.pickerChoices(list, {})[1]

		presence.toggleDevice(list, choice)

		assert.are.equal(1, #list)
	end)
end)
