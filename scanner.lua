-- vim: set ft=lua:

-- Running the Bluetooth scanner, loaded by init.lua. It adds the `_ensureScannerApp`, `_startScanner`,
-- `_restartScanner`, `_restartStalledScanner`, `_stopScanner` and `_scanNearby` methods.
--
-- The scanner is a tiny Swift app (`scan.swift`) compiled on first use rather than shipped as a
-- binary, so a release needs no macOS build and a locally built app is never quarantined. It has to
-- be its own app: launched as Hammerspoon's child, macOS blames Hammerspoon, whose Info.plist has no
-- Bluetooth usage description, and kills it. Launching through LaunchServices (`open`) makes the app
-- responsible for itself; it reports back through a named pipe.

return function(obj, presence)
	local BUNDLE_ID = "net.larve.ProximityLockScanner"
	local RESTART_DELAY = 5
	-- A phone that is fine leaves gaps of up to about 18 s between readings, so restarting any earlier
	-- would often restart a working scanner.
	local STALL_SECONDS = 30
	local LONG_GAP_SECONDS = 10
	local SUSPEND_GAP = 10
	local MAX_DEAF_BACKOFF = 300
	local STOP_POLL = 0.25
	local STOP_GRACE = 2
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

	local function scannerLogPath(self) return self._scannerLogPath or cacheDir() .. "/scanner.log" end

	-- The scanner writes its own events to the same file; this adds the ones it cannot (it is killed
	-- with SIGKILL, and it is the spoon that decides to start it).
	function obj:_noteScanner(text)
		if not self.scannerLog then return end
		local handle = io.open(scannerLogPath(self), "a")
		if not handle then return end
		handle:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " spoon: ", text, "\n")
		handle:close()
	end

	-- Names the built app: any change to the sources or to the build script gives a new name, so the
	-- next start rebuilds. The script builds into a scratch directory and renames it into place, so a
	-- half-built app is never used.
	local function sourceHash(self)
		if self._sourceHash then return self._sourceHash end
		local parts = {}
		for _, file in ipairs({ "build-scanner.sh", "scan.swift", "Info.plist" }) do
			local handle = assert(io.open(hs.spoons.resourcePath(file), "rb"))
			table.insert(parts, handle:read("a"))
			handle:close()
		end
		self._sourceHash = hs.hash.SHA256(table.concat(parts, "\0")):sub(1, 12)
		return self._sourceHash
	end

	-- Calls back with the path of the scanner app built from the current sources, building it first
	-- if needed (a few seconds, once per version of the sources), or with nil if the build failed.
	function obj:_ensureScannerApp(callback)
		local hash = sourceHash(self)
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

	-- Asks every scanner instance running now to exit (SIGTERM, so it can stop scanning cleanly; a
	-- SIGKILLed scanner seems to leave CoreBluetooth deaf for the next one), kills any of those still
	-- there after STOP_GRACE, and calls `done` once they are gone, or after twice that if one cannot be
	-- killed. Only the instances seen at the start are tracked: a scanner started meanwhile is left
	-- alone. Two scanners at once do not work, so a new one must not start before this has finished.
	function obj:_stopScanner(done)
		local function running() return hs.application.applicationsForBundleID(BUNDLE_ID) end
		local asked = {}
		for _, app in ipairs(running()) do
			local pid = app:pid()
			if pid then
				asked[pid] = true
				hs.execute(("/bin/kill -TERM %d"):format(pid))
			end
		end
		if next(asked) == nil then return done() end
		self:_noteScanner("asking scanner to stop")

		local function stillThere()
			local found = {}
			for _, app in ipairs(running()) do
				if asked[app:pid()] then table.insert(found, app) end
			end
			return found
		end
		local waited, forced = 0, false
		local function wait()
			local left = stillThere()
			if #left == 0 or waited >= 2 * STOP_GRACE then return done() end
			waited = waited + STOP_POLL
			if waited >= STOP_GRACE and not forced then
				forced = true
				self:_noteScanner("killing scanner")
				for _, app in ipairs(left) do
					app:kill9()
				end
			end
			self:_later(STOP_POLL, wait)
		end
		wait()
	end

	function obj:_onScannerOutput(chunk)
		if not self._engine then return end
		local lines, rest = presence.splitLines((self._buffer or "") .. chunk)
		self._buffer = rest
		local now = hs.timer.secondsSinceEpoch()
		if chunk ~= "" then self._lastOutputAt = now end
		for _, line in ipairs(lines) do
			local ads, state = presence.parseHeartbeat(line)
			if ads then
				self._heartbeat = { at = now, ads = ads, state = state }
				self.log.df("Scanner heartbeat: %d advertisements heard, Bluetooth state %d", ads, state)
			end
			local id, rssi, name = presence.parseReading(line)
			if id then
				local silent = now - self._engine:lastSeen()
				local matched, first = self._engine:feedReading(now, id, name, rssi)
				if matched and self._restartedAt then
					self.log.f(
						"Readings resumed %.0fs after restart (silent for %.0fs)",
						now - self._restartedAt,
						silent
					)
					self._restartedAt = nil
				elseif matched and silent >= LONG_GAP_SECONDS then
					self.log.f("Readings resumed on their own after %.0fs of silence", silent)
				end
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
			if not self._engine or self._scanner or self._listing or self._starting then return end
			if not app then return self:stop() end
			self._starting = true
			self:_stopScanner(function()
				self._starting = nil
				if not self._engine or self._scanner or self._listing then return end
				local fifo = self:_newFifo()
				self._scanner = hs.task.new("/bin/cat", function(exitCode)
					self._scanner = nil
					self.log.wf("Scanner stopped (%s); restarting", tostring(exitCode))
					self:_stopScanner(function()
						self._restart = self:_later(RESTART_DELAY, function() self:_startScanner() end)
					end)
				end, function(_, out)
					self:_onScannerOutput(out or "")
					return true
				end, { fifo })
				self._scanner:start()
				self._startedAt = hs.timer.secondsSinceEpoch()
				self._buffer, self._lastOutputAt, self._heartbeat = "", nil, nil
				self.log.i("Scanner started")
				if self.scannerLog then
					local path = scannerLogPath(self)
					hs.execute(("/usr/bin/touch %q && /bin/chmod 600 %q"):format(path, path))
				end
				self:_noteScanner("starting scanner")

				-- -n: without it, an instance that is still dying would be reused and ignore the arguments.
				local args = { "-n", app, "--args" }
				if self.scannerLog then
					table.insert(args, "--log")
					table.insert(args, scannerLogPath(self))
				end
				if self.scannerRescan then table.insert(args, "--rescan") end
				table.insert(args, fifo)
				for _, device in ipairs(self._engine.devices) do
					table.insert(args, device.needle)
				end
				self._launcher = hs.task.new("/usr/bin/open", nil, args):start()
			end)
		end)
	end

	-- Restarts keep the silence clock running: a scanner that keeps stalling must still reach the
	-- silence limit. Only a deliberate pause (listing) or a wake discards the silence.
	-- Stops the streaming scanner without the usual exit-triggered restart.
	function obj:_pauseScanner()
		if self._restart then self:_cancelLater(self._restart) end
		if self._scanner then
			self._scanner:setCallback(nil)
			self._scanner:terminate()
			self._scanner = nil
		end
		self:_stopScanner(function() end)
	end

	function obj:_restartScanner()
		self:_pauseScanner()
		self._stallRestarted = false
		self._restartedAt = hs.timer.secondsSinceEpoch()
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
	-- What the scanner last said, to tell a deaf CoreBluetooth (heartbeats, few or no advertisements)
	-- from a dead pipe (no bytes at all) in the stall warning.
	function obj:_scannerLifeSigns(now)
		local output = self._lastOutputAt and ("last output %.0fs ago"):format(now - self._lastOutputAt)
			or "no output since the scanner started"
		local beat = self._heartbeat
		local heartbeat = beat
				and ("last heartbeat %.0fs ago: %d advertisements, Bluetooth state %d"):format(
					now - beat.at,
					beat.ads,
					beat.state
				)
			or "no heartbeat yet"
		return output .. "; " .. heartbeat
	end

	-- A scanner that delivers no advertisements at all (not even other devices') after having had time
	-- to settle is restarted again, waiting twice as long each time (up to MAX_DEAF_BACKOFF) so that
	-- Bluetooth being off does not mean a restart every 30 seconds for ever. One that hears the room but
	-- not the tracked device is not restarted again, since that would not help.
	function obj:_scannerDeaf(now)
		local beat = self._heartbeat
		local wait = math.min(STALL_SECONDS * 2 ^ (self._deafRestarts or 0), MAX_DEAF_BACKOFF)
		return beat ~= nil and beat.ads == 0 and now - (self._restartedAt or 0) >= wait
	end

	function obj:_restartStalledScanner(now)
		if self._buildWaiters or self._listing then return end
		local silent = now - self._engine:lastSeen()
		if silent < STALL_SECONDS then
			self._stallRestarted, self._deafRestarts = false, 0
		elseif not self._stallRestarted or self:_scannerDeaf(now) then
			local retry = self._stallRestarted
			self.log.wf(
				"No readings for %.0fs (scanner up %.0fs); restarting scanner (%s)",
				silent,
				now - (self._startedAt or now),
				self:_scannerLifeSigns(now)
			)
			self:_restartScanner()
			self._stallRestarted = true
			if retry then self._deafRestarts = (self._deafRestarts or 0) + 1 end
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
			self:_stopScanner(function() self:_listNearby(app, seconds, callback) end)
		end)
	end

	function obj:_listNearby(app, seconds, callback)
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
	end
end
