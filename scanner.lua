-- vim: set ft=lua:

-- Running the Bluetooth scanner, loaded by init.lua. It adds the `_ensureScannerApp`, `_startScanner`,
-- `_restartScanner`, `_restartStalledScanner`, `_killScanner` and `_scanNearby` methods.
--
-- The scanner is a tiny Swift app (`scan.swift`) compiled on first use rather than shipped as a
-- binary, so a release needs no macOS build and a locally built app is never quarantined. It has to
-- be its own app: launched as Hammerspoon's child, macOS blames Hammerspoon, whose Info.plist has no
-- Bluetooth usage description, and kills it. Launching through LaunchServices (`open`) makes the app
-- responsible for itself; it reports back through a named pipe.

return function(obj, presence)
	local BUNDLE_ID = "net.larve.ProximityLockScanner"
	local RESTART_DELAY = 5
	local STALL_SECONDS = 20
	local SUSPEND_GAP = 10
	local WAKE_DEDUPE = 5

	local NOTE_STYLE = { textSize = 14, radius = 6, strokeWidth = 1 }

	-- A small, brief on-screen note, e.g. for build and scan progress. `style` overrides parts of the
	-- default look (see hs.alert.defaultStyle). Returns the alert's id, for closing it early.
	function obj:_notify(message, seconds, style)
		local merged = {}
		for key, value in pairs(NOTE_STYLE) do
			merged[key] = value
		end
		for key, value in pairs(style or {}) do
			merged[key] = value
		end
		return hs.alert.show(message, merged, hs.screen.mainScreen(), seconds)
	end

	-- hs.timer objects that nothing references can be garbage-collected before they fire, so one-shot
	-- timers are kept here until they fire or are cancelled.
	function obj:_later(delay, fn)
		self._pending = self._pending or {}
		local timer
		timer = hs.timer.doAfter(delay, function()
			self._pending[timer] = nil
			fn()
		end)
		self._pending[timer] = true
		return timer
	end

	function obj:_cancelLater(timer)
		timer:stop()
		if self._pending then self._pending[timer] = nil end
	end

	local function cacheDir() return os.getenv("HOME") .. "/Library/Caches/ProximityLock" end

	-- Names the built app: any change to the sources or to the build script gives a new name, so the
	-- next start rebuilds. The script builds into a scratch directory and renames it into place, so a
	-- half-built app is never used.
	local function sourceHash()
		local parts = {}
		for _, file in ipairs({ "build-scanner.sh", "scan.swift", "Info.plist" }) do
			local handle = assert(io.open(hs.spoons.resourcePath(file), "rb"))
			table.insert(parts, handle:read("a"))
			handle:close()
		end
		return hs.hash.SHA256(table.concat(parts, "\0")):sub(1, 12)
	end

	-- Calls back with the path of the scanner app built from the current sources, building it first
	-- if needed (a few seconds, once per version of the sources), or with nil if the build failed.
	function obj:_ensureScannerApp(callback)
		local hash = sourceHash()
		local app = ("%s/%s/ProximityLockScanner.app"):format(cacheDir(), hash)
		if hs.fs.attributes(app) then return callback(app) end

		self._buildWaiters = self._buildWaiters or {}
		table.insert(self._buildWaiters, callback)
		if #self._buildWaiters > 1 then return end

		self.log.i("Building the Bluetooth scanner (first run, takes a few seconds)")
		self:_notify("ProximityLock: building the Bluetooth scanner…", 4)
		hs.fs.mkdir(cacheDir())
		self._buildTask = hs.task
			.new("/bin/sh", function(exitCode, _, stderr)
				local waiters, built = self._buildWaiters, exitCode == 0
				self._buildWaiters = nil
				if built then
					self.log.i("Scanner built")
				else
					self.log.ef("Building the scanner failed (%s): %s", tostring(exitCode), tostring(stderr))
					self:_notify(
						"ProximityLock: could not build the scanner. Install the Xcode command line tools (xcode-select --install) and turn it on again.",
						8
					)
				end
				for _, waiter in ipairs(waiters) do
					waiter(built and app or nil)
				end
			end, {
				hs.spoons.resourcePath("build-scanner.sh"),
				(hs.spoons.resourcePath("scan.swift"):gsub("/scan%.swift$", "")),
				cacheDir(),
				hash,
			})
			:start()
	end

	-- A fresh named pipe for the scanner to write to, replacing any left by a crashed run.
	function obj:_newFifo(suffix)
		local fifo = hs.fs.temporaryDirectory() .. "/proximitylock" .. (suffix or "") .. ".fifo"
		hs.execute(("/bin/rm -f %q && /usr/bin/mkfifo %q"):format(fifo, fifo))
		return fifo
	end

	function obj:_killScanner()
		for _, app in ipairs(hs.application.applicationsForBundleID(BUNDLE_ID)) do
			app:kill9()
		end
	end

	function obj:_onScannerOutput(chunk)
		local lines, rest = presence.splitLines((self._buffer or "") .. chunk)
		self._buffer = rest
		local now = hs.timer.secondsSinceEpoch()
		for _, line in ipairs(lines) do
			local id, rssi, name = presence.parseReading(line)
			if id then
				local _, first = self._engine:feedReading(now, id, name, rssi)
				if first then self.log.f("Device found: %s (%d dBm)", name ~= "" and name or id, rssi) end
			end
		end
	end

	-- `cat` reads the pipe and ends when the app exits, which triggers the restart; the app is
	-- launched after the reader so its open-for-write does not block.
	function obj:_startScanner()
		self:_ensureScannerApp(function(app)
			-- Several starts can wait for the same build; only one scanner may run, and a listing
			-- starts it again when it ends.
			if not self._engine or self._scanner or self._listing then return end
			if not app then return self:stop() end
			local fifo = self:_newFifo()
			self._scanner = hs.task.new("/bin/cat", function(exitCode)
				self._scanner = nil
				self.log.wf("Scanner stopped (%s); restarting", tostring(exitCode))
				self:_killScanner()
				self._restart = self:_later(RESTART_DELAY, function() self:_startScanner() end)
			end, function(_, out)
				self:_onScannerOutput(out or "")
				return true
			end, { fifo })
			self._scanner:start()
			self.log.i("Scanner started")

			-- -n: without it, an instance that is still dying would be reused and ignore the arguments.
			local args = { "-n", app, "--args", fifo }
			for _, device in ipairs(self._engine.devices) do
				table.insert(args, device.needle)
			end
			self._launcher = hs.task.new("/usr/bin/open", nil, args):start()
		end)
	end

	-- Restarts keep the silence clock running: a scanner that keeps stalling must still reach the
	-- silence limit. Only a deliberate pause (listing) or a wake discards the silence.
	-- Stops the streaming scanner without the usual exit-triggered restart.
	function obj:_pauseScanner()
		if self._restart then self._restart:stop() end
		if self._scanner then
			self._scanner:setCallback(nil)
			self._scanner:terminate()
			self._scanner = nil
		end
		self:_killScanner()
	end

	function obj:_restartScanner()
		self:_pauseScanner()
		self._stallRestarted = false
		self:_startScanner()
	end

	-- CoreBluetooth scanning goes quiet across sleep while the app and pipe still look alive.
	-- The silence during sleep says nothing about the device, and a verdict reached from it (the
	-- ticker can run before the wake event arrives) is not worth acting on, so start over. The wake
	-- event and the gap seen by `_tick` both land here; the second is ignored.
	function obj:_onWake()
		local now = hs.timer.secondsSinceEpoch()
		if self._wokeAt and now - self._wokeAt < WAKE_DEDUPE then return end
		self._wokeAt = now
		self.log.i("Woke from sleep; restarting scanner")
		self._engine:rearm(now)
		self:_restartScanner()
	end

	-- One step of the once-a-second ticker. A gap far longer than a second means the Mac slept.
	function obj:_tick(now)
		local last = self._lastTick
		self._lastTick = now
		if last and now - last > SUSPEND_GAP then return self:_onWake() end
		self._engine:tick(now)
		self:_restartStalledScanner(now)
		self:_refreshMenubar()
	end

	-- A scanner that stops delivering is restarted once per stall; the usual exit-triggered restart
	-- can be lost when hs.task throws from its termination handler.
	function obj:_restartStalledScanner(now)
		if self._buildWaiters or self._listing then return end
		local silent = now - self._engine:lastSeen()
		if silent < STALL_SECONDS then
			self._stallRestarted = false
		elseif not self._stallRestarted then
			self.log.wf("No readings for %.0fs; restarting scanner", silent)
			self:_restartScanner()
			self._stallRestarted = true
		end
	end

	-- Hears every device for a few seconds and calls back with a list of { id, name, rssi } sorted by
	-- signal strength (strongest first), or with nil if the scanner could not be built. Two scanner
	-- instances do not work at once (the second hears nothing), so a running scanner is paused for
	-- the duration and started again afterwards.
	function obj:_scanNearby(seconds, callback)
		self:_ensureScannerApp(function(app)
			if not app then return callback(nil) end
			self._listing = true
			self:_pauseScanner()
			local fifo = self:_newFifo("-list")
			local text = ""
			local reader
			-- If the app never opens its end of the pipe, `cat` would wait forever.
			local giveUp = self:_later(seconds + 15, function() reader:terminate() end)
			reader = hs.task.new("/bin/cat", function()
				self:_cancelLater(giveUp)
				-- The list arrives in one burst just before the app exits, and hs.task can report the
				-- exit before it has delivered the last of the output, so parse after a short wait.
				self:_later(0.5, function()
					self._listing = nil
					if self._engine then
						self._engine:resetSilence(hs.timer.secondsSinceEpoch())
						self:_startScanner()
					end
					callback(presence.parseDeviceList(text))
				end)
			end, function(_, out)
				text = text .. (out or "")
				return true
			end, { fifo })
			reader:start()
			self._lister =
				hs.task.new("/usr/bin/open", nil, { "-n", app, "--args", "--list", tostring(seconds), fifo }):start()
		end)
	end
end
