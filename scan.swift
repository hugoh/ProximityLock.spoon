// Usage:
//   ProximityLockScanner [--log <file>] [--rescan] <pipe> <needle>...  stream matching advertisements until killed
//   ProximityLockScanner --list <seconds> <pipe> report every device heard once, then exit
//
// <pipe> may be - for standard output, to watch the signals from a terminal.
//
// Every line written to the pipe starts with its type, and the spoon drops anything else:
//   R<TAB><identifier><TAB><rssi><TAB><name>   one advertisement from a matching device
//   H<TAB><ads><TAB><state>                    every 10 s: advertisements from any device since the
//                                              last one, and the CBManagerState raw value
// Names are untrusted: control characters are replaced and the length is capped. A needle
// matches when it is contained in the device's name or identifier, ignoring case. The scanner runs as
// its own app (see Info.plist) so macOS asks for Bluetooth permission for it, not for Hammerspoon.

import CoreBluetooth
import Foundation

// A write to a closed pipe must come back as an error (see `send`), not kill the process.
signal(SIGPIPE, SIG_IGN)

struct Options {
    var logPath: String?
    var rescan = false
    var listSeconds: Double?
    var pipe = ""
    var needles: [String] = []
    var listing: Bool { listSeconds != nil }
}

// --log <file>: also append timestamped events (start, heartbeats, readings, Bluetooth state) to a
// file, as evidence of what the scanner did when the pipe to the spoon stalls.
// --rescan: restart the Bluetooth scan by itself when a matched device has been quiet for a while.
func parseOptions(_ arguments: [String]) -> Options? {
    var options = Options()
    var rest = Array(arguments.dropFirst())
    if let flag = rest.firstIndex(of: "--log"), flag + 1 < rest.count {
        options.logPath = rest[flag + 1]
        rest.removeSubrange(flag...(flag + 1))
    }
    options.rescan = rest.contains("--rescan")
    rest.removeAll { $0 == "--rescan" }
    let listing = rest.count > 2 && rest[0] == "--list"
    if listing {
        options.listSeconds = Double(rest[1]) ?? 6
        rest.removeFirst(2)
    }
    guard let pipe = rest.first, !pipe.isEmpty, !pipe.hasPrefix("--") else { return nil }
    options.pipe = pipe
    if !options.listing { options.needles = rest.dropFirst().map { $0.lowercased() } }
    return options
}

func requireOptions(_ arguments: [String]) -> Options {
    guard let options = parseOptions(arguments) else {
        let usage = "usage: ProximityLockScanner [--log <file>] [--rescan] <pipe|-> <needle>...\n"
            + "       ProximityLockScanner --list <seconds> <pipe|->\n"
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    return options
}

func openOutput(_ path: String) -> FileHandle {
    guard let handle = path == "-" ? FileHandle.standardOutput : FileHandle(forWritingAtPath: path) else {
        FileHandle.standardError.write(Data("cannot open \(path) for writing\n".utf8))
        exit(1)
    }
    return handle
}

let options = requireOptions(CommandLine.arguments)
let output = openOutput(options.pipe)
var eventLog = options.logPath.flatMap(openEventLog)

func isOversized(_ path: String) -> Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    return (size ?? 0) > 1_000_000
}

// Appends to the file, first moving a log over 1 MB aside so it cannot grow without bound.
func openEventLog(_ path: String) -> FileHandle? {
    let manager = FileManager.default
    if isOversized(path) {
        try? manager.removeItem(atPath: path + ".1")
        try? manager.moveItem(atPath: path, toPath: path + ".1")
    }
    // O_APPEND, because the spoon appends its own notes to the same file. 0600: it records when you
    // were near the Mac.
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

// A scanner can run for days, so the size is checked while it runs, not just at start.
func rotateEventLogIfLarge() {
    guard let path = options.logPath, isOversized(path) else { return }
    eventLog = openEventLog(path)
}

let timestamp = ISO8601DateFormatter()

func record(_ event: String) {
    eventLog?.write(Data("\(timestamp.string(from: Date())) \(event)\n".utf8))
}

// Advertised names are untrusted; a tab or newline in one could forge extra fields or lines in the pipe.
let unsafeCharacters = CharacterSet.controlCharacters.union(.newlines)
let maxNameCharacters = 64

func sanitized(_ text: String) -> String {
    let safe = text.map { $0.unicodeScalars.contains(where: unsafeCharacters.contains) ? " " : $0 }
    return String(safe.prefix(maxNameCharacters))
}

// The spoon gets every reading; the log gets at most one a second, which is enough to see gaps.
var lastReadingLoggedAt = Date.distantPast

// Writes to the pipe. A closed pipe means the spoon stopped reading, so the scanner ends.
func send(_ text: String) {
    do {
        try output.write(contentsOf: Data(text.utf8))
    } catch {
        record("scanner stopping (pipe closed: \(error.localizedDescription))")
        exit(0)
    }
}

func write(id: String, rssi: Int, name: String, note: String = "") {
    let now = Date()
    if now.timeIntervalSince(lastReadingLoggedAt) >= 1 {
        record("reading \(rssi) \(name)\(note)")
        lastReadingLoggedAt = now
    }
    send("R\t\(id)\t\(rssi)\t\(name)\n")
}

final class Scanner: NSObject, CBCentralManagerDelegate {
    lazy var central = CBCentralManager(delegate: self, queue: nil)
    var heard: [String: (name: String, rssi: Int)] = [:]
    var advertisementsSinceHeartbeat = 0
    // An iPhone rotates its address and sends most advertisements without a name, so once a device
    // has matched by name its identifier is remembered and later advertisements match by that.
    var matchedIds = Set<String>()
    var lastHeard: [String: Date] = [:]
    var lastRescanAt = Date.distantPast
    let quietLimit: TimeInterval = 10
    // A device that rotated its address leaves a stale identifier behind; forgetting it keeps that, or
    // a device that has really gone, from triggering a re-scan every few seconds forever.
    let forgetAfter: TimeInterval = 60

    // Also fires when Bluetooth power-cycles (e.g. after sleep), which restarts the scan.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        record("bluetooth state \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        startScan()
    }

    func startScan() {
        central.scanForPeripherals(
            withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    // CoreBluetooth sometimes keeps delivering other devices' advertisements but stops delivering a
    // tracked one; starting the scan again brings it back much sooner than restarting the app.
    func rescanIfQuiet() {
        let now = Date()
        lastHeard = lastHeard.filter { now.timeIntervalSince($0.value) <= forgetAfter }
        guard options.rescan, !options.listing, central.state == .poweredOn,
            now.timeIntervalSince(lastRescanAt) > quietLimit,
            lastHeard.values.contains(where: { now.timeIntervalSince($0) > quietLimit })
        else { return }
        record(
            "rescan: a matched device was quiet for over \(Int(quietLimit)) s; "
                + "ads since last heartbeat=\(advertisementsSinceHeartbeat)")
        central.stopScan()
        startScan()
        lastRescanAt = now
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        advertisementsSinceHeartbeat += 1
        let rssi = RSSI.intValue
        guard rssi != 127 else { return }  // CoreBluetooth's "unavailable" value
        let name = sanitized(advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "")
        let id = peripheral.identifier.uuidString

        if options.listing {
            let known = heard[id]
            heard[id] = (name.isEmpty ? known?.name ?? "" : name, max(rssi, known?.rssi ?? Int.min))
            return
        }
        let haystacks = [id.lowercased(), name.lowercased()]
        let byNeedle = options.needles.contains(where: { needle in haystacks.contains { $0.contains(needle) } })
        guard byNeedle || matchedIds.contains(id) else { return }
        matchedIds.insert(id)
        lastHeard[id] = Date()
        write(id: id, rssi: rssi, name: name, note: byNeedle ? "" : " (by remembered identifier)")
    }

    // Tells the spoon whether the scanner hears anything at all, to tell "the phone went quiet" from
    // "the scanner went deaf". Counts every advertisement, matching or not. Also lets a scanner whose
    // reader is gone (Hammerspoon died) fail to write and exit.
    func heartbeat() {
        rotateEventLogIfLarge()
        record("heartbeat ads=\(advertisementsSinceHeartbeat) state=\(central.state.rawValue)")
        send("H\t\(advertisementsSinceHeartbeat)\t\(central.state.rawValue)\n")
        advertisementsSinceHeartbeat = 0
    }

    func report() {
        for (id, device) in heard.sorted(by: { $0.value.rssi > $1.value.rssi }) {
            write(id: id, rssi: device.rssi, name: device.name)
        }
    }
}

record("scanner started (pid \(ProcessInfo.processInfo.processIdentifier))")
let scanner = Scanner()
_ = scanner.central
if let listSeconds = options.listSeconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + listSeconds) {
        scanner.report()
        exit(0)
    }
}
// Kept at top level: sources that go out of scope are cancelled, which would leave the signals ignored.
var stopSources: [DispatchSourceSignal] = []
if !options.listing {
    // Log why the scanner ends where it can. SIGKILL, which the spoon falls back to, cannot be caught,
    // so the spoon notes that itself; a closed pipe is reported by `send`.
    for (name, number) in [("SIGTERM", SIGTERM), ("SIGINT", SIGINT), ("SIGHUP", SIGHUP)] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            record("scanner stopping (\(name))")
            scanner.central.stopScan()
            exit(0)
        }
        source.resume()
        stopSources.append(source)
    }
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in scanner.heartbeat() }
    if options.rescan { Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in scanner.rescanIfQuiet() } }
}
RunLoop.main.run()
