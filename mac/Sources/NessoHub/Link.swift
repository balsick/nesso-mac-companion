import CoreBluetooth
import Foundation

/// The BLE connection to the Nesso. Finds it by service UUID, keeps it
/// connected, and turns the RX/TX characteristics into a line-based channel.
final class Link: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  var onReady: (() -> Void)?
  var onLine: ((String) -> Void)?
  var onLost: (() -> Void)?
  /// Fires whenever `status` changes, for the menu bar.
  var onStatus: (() -> Void)?
  /// Fires once, when macOS has answered the Bluetooth permission question
  /// either way. Until then a second permission prompt would only bury the
  /// first.
  var onSettled: (() -> Void)?
  private var settled = false

  private(set) var isReady = false
  /// A human-readable line: "searching", "connected", "Bluetooth is off"...
  private(set) var status = "starting" {
    didSet { if status != oldValue { onStatus?() } }
  }

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var rx: CBCharacteristic?
  private var incoming = Data()
  private var outgoing: [Data] = []
  private var writing = false

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  /// Queues one line. Writes go out with response, one at a time, so a long
  /// line (an icon) arrives in order and nothing is dropped.
  func send(_ line: String) {
    guard isReady, let peripheral else { return }
    let data = Data((line + "\n").utf8)
    let chunk = peripheral.maximumWriteValueLength(for: .withResponse)
    var at = 0
    while at < data.count {
      let end = min(at + chunk, data.count)
      outgoing.append(data.subdata(in: at..<end))
      at = end
    }
    pump()
  }

  private func pump() {
    guard !writing, let rx, let peripheral, !outgoing.isEmpty else { return }
    writing = true
    peripheral.writeValue(outgoing[0], for: rx, type: .withResponse)
  }

  private func reset() {
    isReady = false
    status = "searching"
    rx = nil
    peripheral = nil
    incoming.removeAll()
    outgoing.removeAll()
    writing = false
  }

  private func scan() {
    guard central.state == .poweredOn else { return }
    // macOS may already hold a connection to it from a previous run.
    if let known = central.retrieveConnectedPeripherals(withServices: [Wire.service]).first {
      connect(known)
      return
    }
    status = "searching"
    log("ble", "scanning for the Nesso")
    central.scanForPeripherals(withServices: [Wire.service])
  }

  private func connect(_ p: CBPeripheral) {
    central.stopScan()
    peripheral = p
    p.delegate = self
    status = "connecting"
    log("ble", "connecting to \(p.name ?? p.identifier.uuidString)")
    central.connect(p)
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if !settled, central.state != .unknown, central.state != .resetting {
      settled = true
      onSettled?()
    }
    switch central.state {
    case .poweredOn: scan()
    case .unauthorized:
      status = "Bluetooth permission denied"
      log("ble", "Bluetooth permission denied: allow it in System Settings > Privacy & Security > Bluetooth")
    case .poweredOff:
      status = "Bluetooth is off"
      log("ble", "Bluetooth is off")
    default:
      log("ble", "Bluetooth state \(central.state.rawValue)")
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Wire.service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    log("ble", "connection failed: \(error?.localizedDescription ?? "unknown")")
    reset()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan() }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                      error: Error?) {
    log("ble", "disconnected")
    let wasReady = isReady
    reset()
    if wasReady { onLost?() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan() }
  }

  // MARK: CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == Wire.service }) else { return }
    peripheral.discoverCharacteristics([Wire.rx, Wire.tx], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                  error: Error?) {
    for c in service.characteristics ?? [] {
      if c.uuid == Wire.rx { rx = c }
      if c.uuid == Wire.tx { peripheral.setNotifyValue(true, for: c) }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                  error: Error?) {
    guard characteristic.uuid == Wire.tx, characteristic.isNotifying, rx != nil else { return }
    isReady = true
    status = "connected"
    log("ble", "ready (write chunk \(peripheral.maximumWriteValueLength(for: .withResponse)) bytes)")
    onReady?()
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                  error: Error?) {
    guard characteristic.uuid == Wire.tx, let value = characteristic.value else { return }
    incoming.append(value)
    while let newline = incoming.firstIndex(of: UInt8(ascii: "\n")) {
      let line = String(decoding: incoming[incoming.startIndex..<newline], as: UTF8.self)
      incoming.removeSubrange(incoming.startIndex...newline)
      if !line.isEmpty { onLine?(line) }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                  error: Error?) {
    if let error { log("ble", "write failed: \(error.localizedDescription)") }
    writing = false
    if !outgoing.isEmpty { outgoing.removeFirst() }
    pump()
  }
}
