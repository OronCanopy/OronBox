import Cocoa
import FlutterMacOS
import IOBluetooth

@main
class AppDelegate: FlutterAppDelegate {
  /// Bridge to the "open with" file channel registered in MainFlutterWindow.
  /// Cold-start files land in [pendingOpenPaths] and are pulled by Dart via
  /// getInitialFile once the channel handler is up; warm-start files are
  /// pushed straight away through [fileOpenChannel].
  static var fileOpenChannel: FlutterMethodChannel?
  private static var pendingOpenPaths: [String] = []
  private static var fileOpenDeliveryReady = false

  static func activateFileOpenDelivery() -> String? {
    fileOpenDeliveryReady = true
    let initial = pendingOpenPaths.isEmpty ? nil : pendingOpenPaths.removeFirst()
    DispatchQueue.main.async {
      while !pendingOpenPaths.isEmpty, let channel = fileOpenChannel {
        channel.invokeMethod("openFile", arguments: pendingOpenPaths.removeFirst())
      }
    }
    return initial
  }

  private static func pushOrQueue(_ path: String) {
    if fileOpenDeliveryReady, let channel = fileOpenChannel {
      channel.invokeMethod("openFile", arguments: path)
    } else {
      pendingOpenPaths.append(path)
    }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.arguments.contains("--nogui") {
      NSApp.setActivationPolicy(.prohibited)
      return
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // MARK: - "Open with OronBox" file handling

  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    Self.pushOrQueue(filename)
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    for filename in filenames {
      Self.pushOrQueue(filename)
    }
  }
}

final class MacOSRfcommChannel: NSObject, FlutterStreamHandler, IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceInquiryDelegate, IOBluetoothDeviceAsyncCallbacks {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let scanEventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var scanEventSink: FlutterEventSink?
  private var rfcommChannel: IOBluetoothRFCOMMChannel?
  private var inquiry: IOBluetoothDeviceInquiry?
  private var inquiryLoopRunning = false
  private var scanResults: [String: [String: Any]] = [:]
  private var connectGeneration: UInt64 = 0
  private var pendingSdpQuery: MacOSSdpQueryRequest?
  private var pendingRfcommOpens: [RfcommOpenState] = []
  private var pendingWrite: RfcommWriteState?
  private let stateQueue = DispatchQueue(label: "org.oroncanopy.oronbox.rfcomm.state")
  private var readClosed = false

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: OronBoxChannelNames.classicSpp,
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: OronBoxChannelNames.classicSppEvents,
      binaryMessenger: messenger
    )
    scanEventChannel = FlutterEventChannel(
      name: OronBoxChannelNames.classicSppScanEvents,
      binaryMessenger: messenger
    )
    super.init()

    methodChannel.setMethodCallHandler(handle)
    eventChannel.setStreamHandler(self)
    scanEventChannel.setStreamHandler(MacOSScanStreamHandler(owner: self))
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  fileprivate func onScanListen(_ events: @escaping FlutterEventSink) {
    scanEventSink = events
  }

  fileprivate func onScanCancel() {
    scanEventSink = nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermissions":
      result(nil)
    case "startScan":
      startScan(result: result)
    case "stopScan":
      stopScan(result: result)
    case "connect":
      connect(call, result: result)
    case "send":
      send(call, result: result)
    case "disconnect":
      disconnect()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScan(result: @escaping FlutterResult) {
    stopInquiry()
    scanResults.removeAll()
    inquiryLoopRunning = true

    for item in pairedDevices() {
      rememberScanDevice(item)
    }

    let status = startInquiry()
    if status == kIOReturnSuccess {
      result(nil)
    } else {
      inquiryLoopRunning = false
      self.inquiry = nil
      result(FlutterError(code: "SCAN_FAILED", message: "Bluetooth inquiry failed: \(status)", details: nil))
    }
  }

  private func stopScan(result: @escaping FlutterResult) {
    inquiryLoopRunning = false
    stopInquiry()
    result(Array(scanResults.values))
  }

  private func stopInquiry() {
    inquiry?.stop()
    inquiry = nil
  }

  /// Classic inquiry is deliberately repeated while the Flutter scan is
  /// active. A single inquiry can finish before a newly discoverable VelaOS
  /// device answers, while CoreBluetooth may already have shown its UUID.
  /// Repeating the inquiry gives us the real address required by SPP.
  @discardableResult
  private func startInquiry() -> IOReturn {
    let next = IOBluetoothDeviceInquiry(delegate: self)
    next?.updateNewDeviceNames = true
    inquiry = next
    let status = next?.start() ?? kIOReturnError
    if status != kIOReturnSuccess {
      inquiry = nil
    }
    return status
  }

  private func pairedDevices() -> [[String: Any]] {
    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return devices.compactMap(scanDeviceMap)
  }

  private func scanDeviceMap(_ device: IOBluetoothDevice) -> [String: Any]? {
    guard let address = device.addressString, !address.isEmpty else {
      return nil
    }
    return [
      "addr": address,
      "name": device.nameOrAddress ?? "Unknown device",
      "connectType": "spp",
    ]
  }

  private func rememberScanDevice(_ item: [String: Any]) {
    guard let address = item["addr"] as? String, !address.isEmpty else {
      return
    }
    scanResults[address] = item
    DispatchQueue.main.async {
      self.scanEventSink?(item)
    }
  }

  private func connect(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let address = args["addr"] as? String,
      !address.isEmpty
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "addr is required", details: nil))
      return
    }
    let serviceUuid = args["serviceUuid"] as? String
    let fallbackChannels = (args["fallbackChannels"] as? [Int]) ?? [5, 1]
    guard let device = IOBluetoothDevice(addressString: address) else {
      result(FlutterError(code: "CONNECT_FAILED", message: "Bluetooth device not found", details: nil))
      return
    }

    let generation = stateQueue.sync { () -> UInt64 in
      connectGeneration += 1
      return connectGeneration
    }
    disconnect(cancelConnect: false, emitEvent: false)

    DispatchQueue.global(qos: .userInitiated).async {
      var errors: [String] = []
      func uniqueChannels(_ values: [Int]) -> [Int] {
        var channels = [Int]()
        for channel in values
          where (1...30).contains(channel) && !channels.contains(channel) {
          channels.append(channel)
        }
        return channels
      }

      func attempt(_ channels: [Int], discoveryMs: Int) -> Bool {
        for channelNumber in channels {
          if !self.isCurrentGeneration(generation) {
            return false
          }

          var channel: IOBluetoothRFCOMMChannel?
          let status = self.openRfcommChannel(
            device: device,
            channelNumber: channelNumber,
            generation: generation,
            channel: &channel
          )
          if status == kIOReturnSuccess, let channel {
            let accepted = self.stateQueue.sync { () -> Bool in
              guard self.connectGeneration == generation else {
                return false
              }
              self.rfcommChannel = channel
              self.readClosed = false
              return true
            }
            if !accepted {
              channel.close()
              return false
            }
            DispatchQueue.main.async {
              result([
                "channel": channelNumber,
                "discoveryMs": discoveryMs,
                "channels": channels,
              ])
            }
            return true
          }
          channel?.close()
          errors.append("channel \(channelNumber): \(status)")
        }
        return false
      }

      // Match Android: try the profile's known channels immediately, and
      // only pay the SDP discovery cost after those channels fail.
      if attempt(uniqueChannels(fallbackChannels), discoveryMs: 0) {
        return
      }
      if !self.isCurrentGeneration(generation) {
        DispatchQueue.main.async {
          result(FlutterError(code: "CONNECT_CANCELLED", message: "SPP connect was cancelled", details: nil))
        }
        return
      }

      let discoveryStarted = Date()
      let discoveredChannels = self.discoverRfcommChannels(
        device: device,
        generation: generation,
        serviceUuid: serviceUuid
      )
      let discoveryMs = Int(Date().timeIntervalSince(discoveryStarted) * 1000)
      if attempt(uniqueChannels(discoveredChannels), discoveryMs: discoveryMs) {
        return
      }
      if !self.isCurrentGeneration(generation) {
        DispatchQueue.main.async {
          result(FlutterError(code: "CONNECT_CANCELLED", message: "SPP connect was cancelled", details: nil))
        }
        return
      }

      DispatchQueue.main.async {
        let details = errors.isEmpty ? "No RFCOMM channel available" : errors.joined(separator: ", ")
        result(FlutterError(code: "CONNECT_FAILED", message: "connect failed: \(details)", details: nil))
      }
    }
  }

  private func send(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let data = args["data"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "data is required", details: nil))
      return
    }
    guard let channel = stateQueue.sync(execute: { rfcommChannel }) else {
      result(FlutterError(code: "NOT_CONNECTED", message: "SPP socket is not connected", details: nil))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let bytes = [UInt8](data.data)
      let mtu = Int(channel.getMTU())
      let chunkSize = min(max(mtu, 1), 1024)
      var offset = 0
      var status: IOReturn = kIOReturnSuccess

      while offset < bytes.count {
        let length = min(chunkSize, bytes.count - offset)
        let payload = Array(bytes[offset..<(offset + length)])
        let writeState = RfcommWriteState(payload: payload, channel: channel)
        let accepted = self.stateQueue.sync { () -> Bool in
          guard self.pendingWrite == nil else { return false }
          self.pendingWrite = writeState
          return true
        }
        if !accepted {
          status = kIOReturnBusy
          break
        }

        DispatchQueue.main.async {
          let immediateStatus = writeState.payload.withUnsafeBytes { buffer -> IOReturn in
            guard let base = buffer.baseAddress else {
              return kIOReturnBadArgument
            }
            return channel.writeAsync(
              UnsafeMutableRawPointer(mutating: base),
              length: UInt16(writeState.payload.count),
              refcon: nil
            )
          }
          if immediateStatus != kIOReturnSuccess {
            writeState.finish(status: immediateStatus)
          }
        }

        if !writeState.wait(timeout: .now() + 10) {
          writeState.cancel()
          status = kIOReturnTimeout
          self.stateQueue.sync {
            if self.pendingWrite === writeState {
              self.pendingWrite = nil
            }
          }
          break
        }
        status = writeState.snapshot()
        self.stateQueue.sync {
          if self.pendingWrite === writeState {
            self.pendingWrite = nil
          }
        }
        if status != kIOReturnSuccess {
          break
        }
        offset += length
      }

      DispatchQueue.main.async {
        if status == kIOReturnSuccess {
          result(nil)
        } else {
          result(FlutterError(code: "SEND_FAILED", message: "RFCOMM write failed: \(status)", details: nil))
        }
      }
    }
  }

  private func disconnect(cancelConnect: Bool = true, emitEvent: Bool = true) {
    let channel = stateQueue.sync { () -> IOBluetoothRFCOMMChannel? in
      if cancelConnect {
        connectGeneration += 1
      }
      let channel = rfcommChannel
      rfcommChannel = nil
      readClosed = true
      return channel
    }
    channel?.close()
    if emitEvent {
      emitDisconnected()
    }
  }

  private func isCurrentGeneration(_ generation: UInt64) -> Bool {
    stateQueue.sync { connectGeneration == generation }
  }

  private func closeDeviceConnection(_ device: IOBluetoothDevice) {
    if Thread.isMainThread {
      _ = device.closeConnection()
    } else {
      DispatchQueue.main.async {
        _ = device.closeConnection()
      }
    }
  }

  private func discoverRfcommChannels(
    device: IOBluetoothDevice,
    generation: UInt64,
    serviceUuid: String?
  ) -> [Int] {
    guard isCurrentGeneration(generation) else { return [] }
    if let previousQuery = stateQueue.sync(execute: { pendingSdpQuery }) {
      _ = previousQuery.state.wait()
      guard previousQuery.state.isCompleted else {
        // Do not start another query while an older callback can still arrive
        // and be mistaken for the new request.
        return []
      }
      stateQueue.sync {
        if pendingSdpQuery === previousQuery {
          pendingSdpQuery = nil
        }
      }
    }
    let query = MacOSSdpQueryRequest(device: device, generation: generation)
    stateQueue.sync { pendingSdpQuery = query }
    // Query the profile's service UUID when one is available. Xiaomi VelaOS
    // uses the standard Serial Port Profile, while ZeppOS exposes a custom
    // 128-bit service and has no safe channel fallback.
    guard let queryUuid = sdpUuid(serviceUuid) ?? IOBluetoothSDPUUID.uuid16(0x1101) else {
      query.state.finish(status: kIOReturnBadArgument)
      stateQueue.sync {
        if pendingSdpQuery === query {
          pendingSdpQuery = nil
        }
      }
      return []
    }
    var startStatus: IOReturn = kIOReturnError
    let startSemaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      startStatus = device.performSDPQuery(self, uuids: [queryUuid])
      startSemaphore.signal()
    }
    _ = startSemaphore.wait(timeout: .now() + 2)
    if startStatus != kIOReturnSuccess {
      query.state.finish(status: startStatus)
    }
    let status = query.state.wait()
    stateQueue.sync {
      if pendingSdpQuery === query && query.state.isCompleted {
        pendingSdpQuery = nil
      }
    }
    guard status == kIOReturnSuccess, isCurrentGeneration(generation) else {
      return []
    }

    var records = [IOBluetoothSDPServiceRecord]()
    let recordsSemaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
      recordsSemaphore.signal()
    }
    _ = recordsSemaphore.wait(timeout: .now() + 1)
    var channels = [Int]()
    for record in records {
      var channel: BluetoothRFCOMMChannelID = 0
      if record.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
        channels.append(Int(channel))
      }
    }
    return Array(Set(channels)).sorted()
  }

  private func sdpUuid(_ value: String?) -> IOBluetoothSDPUUID? {
    guard let value, let uuid = NSUUID(uuidString: value) else {
      return nil
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    uuid.getBytes(&bytes)
    return IOBluetoothSDPUUID(bytes: bytes, length: bytes.count)
  }

  func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    let query = stateQueue.sync { pendingSdpQuery }
    guard let query,
          let callbackDevice = device,
          (query.device === callbackDevice ||
           query.deviceAddress.caseInsensitiveCompare(
             callbackDevice.addressString ?? ""
           ) == .orderedSame),
          isCurrentGeneration(query.generation) else {
      return
    }
    query.state.finish(status: status)
    stateQueue.sync {
      if pendingSdpQuery === query && query.state.isCompleted {
        pendingSdpQuery = nil
      }
    }
  }

  func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

  func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

  private func openRfcommChannel(
    device: IOBluetoothDevice,
    channelNumber: Int,
    generation: UInt64,
    channel: inout IOBluetoothRFCOMMChannel?
  ) -> IOReturn {
    let state = RfcommOpenState()
    stateQueue.sync {
      pendingRfcommOpens.append(state)
    }
    let deadline = Date().addingTimeInterval(4)

    // IOBluetooth callbacks and channel operations are main-thread based.
    // Use the asynchronous API so a slow RFCOMM attempt cannot block the
    // Flutter main thread or leave a synchronous worker behind on timeout.
    DispatchQueue.main.async {
      var localChannel: IOBluetoothRFCOMMChannel?
      let status = device.openRFCOMMChannelAsync(
        &localChannel,
        withChannelID: BluetoothRFCOMMChannelID(channelNumber),
        delegate: self
      )
      state.start(status: status, channel: localChannel)
    }

    while !state.wait(timeout: .now() + 0.25) {
      if !isCurrentGeneration(generation) {
        cancelRfcommOpen(state, device: device)
        return kIOReturnAborted
      }
      if Date() >= deadline {
        cancelRfcommOpen(state, device: device)
        return kIOReturnTimeout
      }
    }

    let snapshot = state.snapshot()
    if !isCurrentGeneration(generation) {
      snapshot.channel?.close()
      return kIOReturnAborted
    }
    channel = snapshot.channel
    return snapshot.status
  }

  private func cancelRfcommOpen(
    _ state: RfcommOpenState,
    device: IOBluetoothDevice
  ) {
    let deviceToClose = device
    state.cancel()
    let shouldCloseDevice = stateQueue.sync { () -> Bool in
      pendingRfcommOpens.removeAll(where: { $0 === state })
      return rfcommChannel == nil &&
        !pendingRfcommOpens.contains(where: { !$0.hasReceivedCallback })
    }
    if shouldCloseDevice {
      closeDeviceConnection(deviceToClose)
    }
  }

  func rfcommChannelOpenComplete(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!,
    status: IOReturn
  ) {
    let openState = stateQueue.sync {
      pendingRfcommOpens.first(where: { $0.matches(rfcommChannel) })
    }
    if let openState {
      openState.finish(status: status, channel: rfcommChannel)
    } else {
      // A timed-out request may complete after its state was removed. Never
      // leave that late channel open or let it be consumed by a later attempt.
      rfcommChannel?.close()
    }
    stateQueue.sync {
      pendingRfcommOpens.removeAll(where: { $0.hasReceivedCallback })
    }
  }

  func rfcommChannelWriteComplete(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!,
    refcon: UnsafeMutableRawPointer?,
    status: IOReturn
  ) {
    let writeState = stateQueue.sync { pendingWrite }
    guard let writeState, writeState.matches(rfcommChannel) else {
      return
    }
    writeState.finish(status: status)
  }

  private func emitDisconnected() {
    DispatchQueue.main.async {
      self.eventSink?(["event": "disconnected"])
    }
  }

  func rfcommChannelData(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!,
    data dataPointer: UnsafeMutableRawPointer!,
    length dataLength: Int
  ) {
    guard dataLength > 0, let dataPointer,
          stateQueue.sync(execute: {
            !readClosed && self.rfcommChannel === rfcommChannel
          }) else {
      return
    }
    let data = Data(bytes: dataPointer, count: dataLength)
    DispatchQueue.main.async {
      guard self.stateQueue.sync(execute: {
        !self.readClosed && self.rfcommChannel === rfcommChannel
      }) else {
        return
      }
      self.eventSink?(FlutterStandardTypedData(bytes: data))
    }
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    _ = rfcommChannel.close()
    let outcome = stateQueue.sync { () -> (emitDisconnected: Bool, closeDevice: Bool) in
      if self.rfcommChannel === rfcommChannel {
        readClosed = true
        self.rfcommChannel = nil
        return (true, false)
      }

      // A late callback from a previous attempt must not tear down a newer
      // connection. If there is no current channel and no pending open left,
      // however, closing the device clears the half-open Bluetooth session
      // left by the failed attempt and allows the next RFCOMM open to start.
      let hasPendingOpen = pendingRfcommOpens.contains {
        !$0.hasReceivedCallback
      }
      return (false, self.rfcommChannel == nil && !hasPendingOpen)
    }
    if outcome.closeDevice {
      if let device = rfcommChannel.getDevice() {
        closeDeviceConnection(device)
      }
    }
    if outcome.emitDisconnected {
      // The channel itself has already closed. Do not close the device here:
      // an older timed-out RFCOMM attempt can report this callback after a
      // newer channel has been accepted for the same device.
      emitDisconnected()
    }
  }

  func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
    guard sender === inquiry, let item = scanDeviceMap(device) else {
      return
    }
    rememberScanDevice(item)
  }

  func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
    guard sender === inquiry else {
      return
    }
    inquiry = nil
    guard inquiryLoopRunning, !aborted else {
      return
    }
    // The inquiry callback is delivered on the main run loop. Start the next
    // round asynchronously so the completed inquiry can be released first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      guard self.inquiryLoopRunning, self.inquiry == nil else { return }
      let status = self.startInquiry()
      if status != kIOReturnSuccess {
        self.inquiryLoopRunning = false
      }
    }
  }
}

private final class RfcommOpenState {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var status: IOReturn = kIOReturnTimeout
  private var channel: IOBluetoothRFCOMMChannel?
  private var cancelled = false
  private(set) var callbackReceived = false

  func matches(_ channel: IOBluetoothRFCOMMChannel) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !callbackReceived else { return false }
    guard let expectedChannel = self.channel else { return false }
    return expectedChannel === channel
  }

  var hasReceivedCallback: Bool {
    lock.lock()
    defer { lock.unlock() }
    return callbackReceived
  }

  func start(status: IOReturn, channel: IOBluetoothRFCOMMChannel?) {
    lock.lock()
    if cancelled || callbackReceived {
      lock.unlock()
      channel?.close()
      return
    }
    self.channel = channel
    lock.unlock()
    // openRFCOMMChannelAsync returning success only means that the request
    // was queued. The channel is usable only after the open-complete callback.
    if status != kIOReturnSuccess {
      finish(status: status, channel: channel)
    }
  }

  func finish(status: IOReturn, channel: IOBluetoothRFCOMMChannel?) {
    lock.lock()
    defer { lock.unlock() }
    guard !callbackReceived else {
      channel?.close()
      return
    }
    callbackReceived = true
    if cancelled || status != kIOReturnSuccess {
      channel?.close()
      self.status = status
      semaphore.signal()
      return
    }
    self.status = status
    self.channel = channel
    semaphore.signal()
  }

  func wait(timeout: DispatchTime) -> Bool {
    semaphore.wait(timeout: timeout) == .success
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    callbackReceived = true
    let channel = self.channel
    self.channel = nil
    channel?.close()
  }

  func snapshot() -> (status: IOReturn, channel: IOBluetoothRFCOMMChannel?) {
    lock.lock()
    defer { lock.unlock() }
    return (status, channel)
  }
}

private final class MacOSSdpQueryRequest {
  let state = MacOSSdpQueryState()
  weak var device: IOBluetoothDevice?
  let deviceAddress: String
  let generation: UInt64

  init(device: IOBluetoothDevice, generation: UInt64) {
    self.device = device
    self.deviceAddress = device.addressString ?? ""
    self.generation = generation
  }
}

private final class MacOSSdpQueryState {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var completed = false
  private var status: IOReturn = kIOReturnTimeout

  var isCompleted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }

  func finish(status: IOReturn) {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    completed = true
    self.status = status
    semaphore.signal()
  }

  func wait() -> IOReturn {
    _ = semaphore.wait(timeout: .now() + 6)
    lock.lock()
    defer { lock.unlock() }
    return status
  }
}

private final class RfcommWriteState {
  let payload: [UInt8]
  private weak var channel: IOBluetoothRFCOMMChannel?
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var completed = false
  private var status: IOReturn = kIOReturnTimeout

  init(payload: [UInt8], channel: IOBluetoothRFCOMMChannel) {
    self.payload = payload
    self.channel = channel
  }

  func matches(_ callbackChannel: IOBluetoothRFCOMMChannel) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !completed && channel === callbackChannel
  }

  func finish(status: IOReturn) {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    completed = true
    self.status = status
    semaphore.signal()
  }

  func wait(timeout: DispatchTime) -> Bool {
    semaphore.wait(timeout: timeout) == .success
  }

  func cancel() {
    lock.lock()
    completed = true
    lock.unlock()
  }

  func snapshot() -> IOReturn {
    lock.lock()
    defer { lock.unlock() }
    return status
  }
}

private final class MacOSScanStreamHandler: NSObject, FlutterStreamHandler {
  private weak var owner: MacOSRfcommChannel?

  init(owner: MacOSRfcommChannel) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    owner?.onScanListen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.onScanCancel()
    return nil
  }
}
