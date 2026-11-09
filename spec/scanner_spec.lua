-- Busted tests for running the scanner (build, start, read, stall watchdog, listing), with a stubbed
-- `hs` whose tasks, timers and files are driven by hand.

local attach = require("scanner")
local presence = require("presence")

local SOURCES = { ["build-scanner.sh"] = "#!/bin/sh\n", ["scan.swift"] = "// swift\n", ["Info.plist"] = "<plist/>\n" }

local h, obj, sourceDir

local function writeFile(name, content)
	local handle = assert(io.open(sourceDir .. "/" .. name, "wb"))
	handle:write(content)
	handle:close()
end

local function checksum(text)
	local sum = 5381
	for index = 1, #text do
		sum = (sum * 33 + text:byte(index)) % 4294967296
	end
	return ("%08x%04x"):format(sum, #text)
end

local function newTask(path, callback, second, third)
	local task = { path = path, callback = callback, started = false, terminated = false }
	if type(second) == "function" then
		task.stream, task.args = second, third
	else
		task.args = second
	end
	function task:start()
		self.started = true
		return self
	end
	function task:terminate() self.terminated = true end
	function task:setCallback(fn) self.callback = fn end
	table.insert(h.tasks, task)
	return task
end

local function newTimer(delay, fn)
	local timer = { delay = delay, fn = fn, stopped = false }
	function timer:stop() self.stopped = true end
	table.insert(h.timers, timer)
	return timer
end

local function formatted(sink)
	return function(format, ...) table.insert(sink, format:format(...)) end
end

local function setup()
	sourceDir = os.tmpname()
	os.remove(sourceDir)
	assert(os.execute("mkdir -p '" .. sourceDir .. "'"))
	for name, content in pairs(SOURCES) do
		writeFile(name, content)
	end

	h = {
		tasks = {},
		timers = {},
		executed = {},
		alerts = {},
		killed = 0,
		apps = {},
		logs = {},
		appExists = false,
		now = 100,
	}
	_G.hs = {
		task = { new = newTask },
		timer = { doAfter = newTimer, secondsSinceEpoch = function() return h.now end },
		fs = {
			attributes = function() return h.appExists or nil end,
			mkdir = function() end,
			temporaryDirectory = function() return "/tmp/t" end,
		},
		execute = function(command) table.insert(h.executed, command) end,
		hash = { SHA256 = checksum },
		spoons = { resourcePath = function(file) return sourceDir .. "/" .. file end },
		application = { applicationsForBundleID = function() return h.apps end },
		alert = {
			show = function(message, style) table.insert(h.alerts, { message = message, style = style }) end,
		},
		screen = { mainScreen = function() end },
	}
	obj = {
		log = {
			i = function(message) table.insert(h.logs, message) end,
			f = formatted(h.logs),
			wf = formatted(h.logs),
			ef = formatted(h.logs),
		},
		isRunning = function(self) return self._engine ~= nil end,
		stop = function() h.stopped = true end,
	}
	attach(obj, presence)
end

local function startEngine()
	obj._engine = presence.newGroup({ log = function() end }, { "phone" }, 0)
end

local function tasksRunning(path)
	local found = {}
	for _, task in ipairs(h.tasks) do
		if task.path == path then table.insert(found, task) end
	end
	return found
end

local function appPath()
	h.appExists = true
	local path
	obj:_ensureScannerApp(function(app) path = app end)
	h.appExists = false
	return path
end

local function logged(text)
	for _, line in ipairs(h.logs) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

describe("_notify", function()
	before_each(setup)

	it("is small by default and lets the caller override parts of the style", function()
		obj:_notify("hello", 2)
		obj:_notify("warning", 2, { fillColor = { red = 1 } })

		assert.are.equal(14, h.alerts[1].style.textSize)
		assert.is_nil(h.alerts[1].style.fillColor)
		assert.are.equal(14, h.alerts[2].style.textSize)
		assert.are.same({ red = 1 }, h.alerts[2].style.fillColor)
	end)
end)

describe("_ensureScannerApp", function()
	before_each(setup)

	it("uses the cached app without building", function()
		h.appExists = true
		local result

		obj:_ensureScannerApp(function(app) result = app end)

		assert.is_not_nil(result)
		assert.are.equal(0, #h.tasks)
	end)

	it("builds with the script, the source directory, the cache and the hash", function()
		local result
		obj:_ensureScannerApp(function(app) result = app end)

		local build = tasksRunning("/bin/sh")[1]
		assert.is_true(build.started)
		assert.are.equal(sourceDir .. "/build-scanner.sh", build.args[1])
		assert.are.equal(sourceDir, build.args[2])
		assert.are.equal(os.getenv("HOME") .. "/Library/Caches/ProximityLock", build.args[3])
		assert.is_nil(result)

		build.callback(0, "", "")

		assert.are.equal(("%s/%s/ProximityLockScanner.app"):format(build.args[3], build.args[4]), result)
	end)

	it("builds once for callers that arrive during a build, and answers them all", function()
		local results = {}
		obj:_ensureScannerApp(function(app) table.insert(results, app) end)
		obj:_ensureScannerApp(function(app) table.insert(results, app) end)

		assert.are.equal(1, #tasksRunning("/bin/sh"))

		tasksRunning("/bin/sh")[1].callback(0, "", "")

		assert.are.equal(2, #results)
		assert.are.equal(results[1], results[2])
		assert.is_nil(obj._buildWaiters)
	end)

	it("answers nil and tells the user when the build fails", function()
		local called, result = false, "unset"
		obj:_ensureScannerApp(function(app)
			called, result = true, app
		end)

		tasksRunning("/bin/sh")[1].callback(1, "", "swiftc: not found")

		assert.is_true(called)
		assert.is_nil(result)
		assert.is_true(logged("swiftc: not found"))
		assert.is_true(h.alerts[#h.alerts].message:find("could not build", 1, true) ~= nil)
	end)

	it("names the app after the sources and the build script", function()
		local original = appPath()

		writeFile("scan.swift", "// changed\n")
		local afterSource = appPath()
		writeFile("scan.swift", SOURCES["scan.swift"])
		writeFile("build-scanner.sh", "#!/bin/sh\necho changed\n")
		local afterScript = appPath()
		writeFile("build-scanner.sh", SOURCES["build-scanner.sh"])

		assert.are_not.equal(original, afterSource)
		assert.are_not.equal(original, afterScript)
		assert.are_not.equal(afterSource, afterScript)
		assert.are.equal(original, appPath())
	end)
end)

describe("_newFifo", function()
	before_each(setup)

	it("recreates the pipe, with a suffix for the listing pipe", function()
		assert.are.equal("/tmp/t/proximitylock.fifo", obj:_newFifo())
		assert.are.equal("/tmp/t/proximitylock-list.fifo", obj:_newFifo("-list"))
		assert.are.equal(
			'/bin/rm -f "/tmp/t/proximitylock.fifo" && /usr/bin/mkfifo "/tmp/t/proximitylock.fifo"',
			h.executed[1]
		)
	end)
end)

describe("_startScanner", function()
	before_each(setup)

	it("reads the pipe first, then launches the app with the pipe and the needles", function()
		startEngine()
		h.appExists = true

		obj:_startScanner()

		local reader = tasksRunning("/bin/cat")[1]
		local launch = tasksRunning("/usr/bin/open")[1]
		assert.are.same({ "/tmp/t/proximitylock.fifo" }, reader.args)
		assert.are.equal("-n", launch.args[1])
		assert.are.equal("--args", launch.args[3])
		assert.are.equal("/tmp/t/proximitylock.fifo", launch.args[4])
		assert.are.equal("phone", launch.args[5])
		assert.are.equal(reader, obj._scanner)
	end)

	it("starts only one scanner when several starts were waiting for the same build", function()
		startEngine()

		obj:_startScanner()
		obj:_startScanner()
		tasksRunning("/bin/sh")[1].callback(0, "", "")

		assert.are.equal(1, #tasksRunning("/bin/cat"))
		assert.are.equal(1, #tasksRunning("/usr/bin/open"))
	end)

	it("leaves starting to the listing while nearby devices are being listed", function()
		startEngine()
		h.appExists = true
		obj._listing = true

		obj:_startScanner()

		assert.are.equal(0, #h.tasks)
	end)

	it("does nothing when locking was turned off while the build ran", function()
		h.appExists = true

		obj:_startScanner()

		assert.are.equal(0, #h.tasks)
	end)

	it("turns locking off when the scanner cannot be built", function()
		startEngine()

		obj:_startScanner()
		tasksRunning("/bin/sh")[1].callback(1, "", "no compiler")

		assert.is_true(h.stopped)
		assert.are.equal(0, #tasksRunning("/bin/cat"))
	end)

	it("restarts after the reader ends, once the app has been killed", function()
		startEngine()
		h.appExists = true
		local app = { kill9 = function() h.killed = h.killed + 1 end }
		h.apps = { app }
		obj:_startScanner()

		tasksRunning("/bin/cat")[1].callback(0)

		assert.are.equal(1, h.killed)
		assert.are.equal(5, h.timers[#h.timers].delay)
		h.timers[#h.timers].fn()
		assert.are.equal(2, #tasksRunning("/bin/cat"))
	end)
end)

describe("_onScannerOutput", function()
	before_each(function()
		setup()
		startEngine()
	end)

	it("keeps an unfinished line until the rest arrives", function()
		obj:_onScannerOutput("ID-1\t-60\tPhone\nID-1\t-6")

		assert.are.equal("ID-1\t-6", obj._buffer)

		h.now = 105
		obj:_onScannerOutput("2\tPhone\n")

		assert.are.equal("", obj._buffer)
		assert.is_true(obj._engine.devices[1].engine.estimate < -60)
	end)

	it("announces a device once, on its first reading", function()
		obj:_onScannerOutput("ID-1\t-60\tPhone\n")
		h.now = 105
		obj:_onScannerOutput("ID-1\t-61\tPhone\n")

		local announcements = 0
		for _, line in ipairs(h.logs) do
			if line:find("Device found: Phone (-60 dBm)", 1, true) then announcements = announcements + 1 end
		end
		assert.are.equal(1, announcements)
	end)

	it("ignores readings of other devices and lines that are not readings", function()
		obj:_onScannerOutput("ID-2\t-50\tWatch\ngarbage\nID-1\tloud\tPhone\n")

		assert.is_nil(obj._engine.devices[1].engine.estimate)
	end)
end)

describe("silence across a scanner restart", function()
	before_each(function()
		setup()
		startEngine()
		h.appExists = true
	end)

	it("keeps counting when the scanner restarts, so repeated stalls still reach the silence limit", function()
		obj._engine:resetSilence(50)
		h.now = 70

		obj:_restartScanner()

		assert.are.equal(50, obj._engine:lastSeen())
	end)

	it("starts the silence clock over after a nearby-devices listing", function()
		obj._engine:resetSilence(50)
		h.now = 70

		obj:_scanNearby(5, function() end)
		tasksRunning("/bin/cat")[1].callback(0)
		h.timers[#h.timers].fn()

		assert.are.equal(70, obj._engine:lastSeen())
	end)
end)

describe("_restartStalledScanner", function()
	local restarts

	before_each(function()
		setup()
		startEngine()
		restarts = 0
		obj._restartScanner = function() restarts = restarts + 1 end
	end)

	it("leaves a scanner that delivered recently alone", function()
		obj:_restartStalledScanner(15)

		assert.are.equal(0, restarts)
	end)

	it("restarts a silent scanner once per stall", function()
		obj:_restartStalledScanner(25)
		obj:_restartStalledScanner(26)

		assert.are.equal(1, restarts)
	end)

	it("restarts again after a stall that recovered", function()
		obj:_restartStalledScanner(25)
		obj._engine.devices[1].engine.lastSeen = 30
		obj:_restartStalledScanner(31)
		obj:_restartStalledScanner(60)

		assert.are.equal(2, restarts)
	end)

	it("waits while the scanner is being built or the nearby devices are being listed", function()
		obj._buildWaiters = {}
		obj:_restartStalledScanner(60)
		obj._buildWaiters, obj._listing = nil, true
		obj:_restartStalledScanner(60)

		assert.are.equal(0, restarts)
	end)
end)

describe("_pauseScanner", function()
	before_each(setup)

	it("stops the reader without the exit-triggered restart, and kills the app", function()
		startEngine()
		h.appExists = true
		h.apps = { { kill9 = function() h.killed = h.killed + 1 end } }
		obj:_startScanner()
		local reader = obj._scanner

		obj:_pauseScanner()

		assert.is_true(reader.terminated)
		assert.is_nil(reader.callback)
		assert.is_nil(obj._scanner)
		assert.are.equal(1, h.killed)
	end)
end)

describe("_scanNearby", function()
	before_each(setup)

	local function finishListing(output)
		local reader = tasksRunning("/bin/cat")[#tasksRunning("/bin/cat")]
		reader.stream(reader, output)
		reader.callback(0)
		for _, timer in ipairs(h.timers) do
			if timer.delay == 0.5 then timer.fn() end
		end
	end

	it("reports the devices heard, strongest first", function()
		h.appExists = true
		local found

		obj:_scanNearby(6, function(devices) found = devices end)
		local launch = tasksRunning("/usr/bin/open")[1]
		finishListing("ID-1\t-80\tTV\nID-9\t-50\tWatch\n")

		assert.are.same({ "-n", launch.args[2], "--args", "--list", "6", "/tmp/t/proximitylock-list.fifo" }, {
			launch.args[1],
			launch.args[2],
			launch.args[3],
			launch.args[4],
			launch.args[5],
			launch.args[6],
		})
		assert.are.same({
			{ id = "ID-9", name = "Watch", rssi = -50 },
			{ id = "ID-1", name = "TV", rssi = -80 },
		}, found)
	end)

	it("pauses a running scanner for the listing and starts it again after", function()
		startEngine()
		h.appExists = true
		obj:_startScanner()
		local streamReader = obj._scanner

		obj:_scanNearby(6, function() end)

		assert.is_true(streamReader.terminated)
		assert.is_true(obj._listing)
		assert.is_nil(obj._scanner)

		finishListing("")

		assert.is_nil(obj._listing)
		assert.is_not_nil(obj._scanner)
		assert.are_not.equal(streamReader, obj._scanner)
	end)

	it("starts the scanner afterwards if locking was turned on during a listing", function()
		h.appExists = true
		obj:_scanNearby(6, function() end)
		startEngine()
		obj:_startScanner()
		assert.are.equal(0, #tasksRunning("/usr/bin/open") - 1)

		finishListing("")

		assert.is_not_nil(obj._scanner)
		assert.are.equal(1, #tasksRunning("/bin/cat") - 1)
	end)

	it("does not start a scanner afterwards if locking was turned off meanwhile", function()
		startEngine()
		h.appExists = true
		obj:_startScanner()
		obj:_scanNearby(6, function() end)
		obj._engine = nil

		finishListing("")

		assert.is_nil(obj._scanner)
	end)

	it("answers nil when the scanner cannot be built", function()
		local found = "unset"

		obj:_scanNearby(6, function(devices) found = devices end)
		tasksRunning("/bin/sh")[1].callback(1, "", "")

		assert.is_nil(found)
	end)
end)

describe("_later", function()
	before_each(setup)

	it("keeps the timer referenced until it fires or is cancelled", function()
		local fired = 0
		local timer = obj:_later(1, function() fired = fired + 1 end)

		assert.is_true(obj._pending[timer])

		timer.fn()

		assert.are.equal(1, fired)
		assert.is_nil(obj._pending[timer])

		local cancelled = obj:_later(1, function() end)
		obj:_cancelLater(cancelled)

		assert.is_true(cancelled.stopped)
		assert.is_nil(obj._pending[cancelled])
	end)
end)

describe("_tick", function()
	before_each(function()
		setup()
		startEngine()
		obj._refreshMenubar = function() end
		obj._restartScanner = function() h.restarted = (h.restarted or 0) + 1 end
	end)

	it("keeps assessing on ordinary ticks", function()
		obj._engine.devices[1].engine:feed(100, -90)

		obj:_tick(101)
		obj:_tick(102)

		assert.is_nil(h.restarted)
		assert.is_not_nil(obj._engine.devices[1].engine.weakSince)
	end)

	it("treats a long gap between ticks as the Mac having slept, and starts over", function()
		obj._engine.devices[1].engine:feed(100, -90)
		obj:_tick(101)

		obj:_tick(4000)

		assert.are.equal(1, h.restarted)
		assert.are.equal("searching", obj._engine:status())
		assert.is_nil(obj._engine.devices[1].engine.weakSince)
	end)

	it("restarts once when the wake event follows the gap", function()
		obj._engine.devices[1].engine:feed(100, -60)
		obj:_tick(101)
		h.now = 4000
		obj:_tick(4000)
		obj:_onWake()

		assert.are.equal(1, h.restarted)
	end)
end)

describe("wake from sleep", function()
	before_each(function()
		setup()
		startEngine()
		obj._restartScanner = function() h.restarted = (h.restarted or 0) + 1 end
	end)

	it("forgets a verdict reached during the sleep", function()
		local engine = obj._engine.devices[1].engine
		engine:tick(1000)
		assert.are.equal("away", obj._engine.state)

		obj:_onWake()

		assert.are.equal("present", obj._engine.state)
		assert.are.equal("searching", obj._engine:status())
		assert.are.equal(1, h.restarted)
	end)
end)
