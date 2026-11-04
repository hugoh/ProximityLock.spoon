// Usage:
//   ProximityLockScanner <pipe> <needle>...      stream matching advertisements until killed
//   ProximityLockScanner --list <seconds> <pipe> report every device heard once, then exit
//
// Each line written to the pipe is "<identifier>\t<rssi>\t<name>", or blank (a heartbeat). A needle
// matches when it is contained in the device's name or identifier, ignoring case. The scanner runs as
// its own app (see Info.plist) so macOS asks for Bluetooth permission for it, not for Hammerspoon.

import CoreBluetooth
import Foundation

let arguments = CommandLine.arguments
let listing = arguments.count > 3 && arguments[1] == "--list"
let listSeconds = listing ? Double(arguments[2]) ?? 6 : 0
let output = FileHandle(forWritingAtPath: listing ? arguments[3] : arguments[1])!
let needles = listing ? [] : arguments.dropFirst(2).map { $0.lowercased() }

// Advertised names are untrusted; a tab or newline in one could forge extra readings in the pipe.
let unsafeCharacters = CharacterSet.controlCharacters.union(.newlines)

func sanitized(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { unsafeCharacters.contains($0) ? " " : $0 }))
}

func write(id: String, rssi: Int, name: String) {
    // A write to a closed pipe raises SIGPIPE, so the scanner exits when the spoon stops reading.
    output.write(Data("\(id)\t\(rssi)\t\(name)\n".utf8))
}

final class Scanner: NSObject, CBCentralManagerDelegate {
    lazy var central = CBCentralManager(delegate: self, queue: nil)
    var heard: [String: (name: String, rssi: Int)] = [:]

    // Also fires when Bluetooth power-cycles (e.g. after sleep), which restarts the scan.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        guard rssi != 127 else { return }  // CoreBluetooth's "unavailable" value
        let name = sanitized(advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "")
        let id = peripheral.identifier.uuidString

        if listing {
            let known = heard[id]
            heard[id] = (name.isEmpty ? known?.name ?? "" : name, max(rssi, known?.rssi ?? Int.min))
            return
        }
        let haystacks = [id.lowercased(), name.lowercased()]
        guard needles.contains(where: { needle in haystacks.contains { $0.contains(needle) } }) else { return }
        write(id: id, rssi: rssi, name: name)
    }

    func report() {
        for (id, device) in heard.sorted(by: { $0.value.rssi > $1.value.rssi }) {
            write(id: id, rssi: device.rssi, name: device.name)
        }
    }
}

let scanner = Scanner()
_ = scanner.central
if listing {
    DispatchQueue.main.asyncAfter(deadline: .now() + listSeconds) {
        scanner.report()
        exit(0)
    }
}
if !listing {
    // A blank line every few seconds is ignored by the reader, but makes a scanner whose reader is
    // gone (Hammerspoon died) hit SIGPIPE and exit, even if no device it tracks is ever heard.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in output.write(Data("\n".utf8)) }
}
RunLoop.main.run()
