/// USB transport for real Apogee hardware using IOUSBDeviceInterface245.
///
/// Sends vendor-specific USB control transfers to a connected Symphony IO MKI.
/// Uses the legacy IOUSBDeviceInterface245 C API for control endpoint (EP0) access.
///
/// IMPORTANT: On modern macOS, usbaudiod exclusively owns ALL USB interfaces
/// of audio class devices (including the audio control interface). Opening the
/// device at ANY level (IOUSBHostDevice or IOUSBDeviceInterface245) conflicts
/// with the audio driver and breaks audio streaming.
///
/// The correct architecture is to use the HAL plugin (SymphonyIOUSBPlugIn.bundle)
/// which runs inside usbaudiod and has internal USB access. The app should
/// communicate via CoreAudio custom property APIs, not direct USB.
///
/// This transport is kept as a fallback for when the HAL plugin is unavailable
/// (e.g., for firmware updates, diagnostics, or when audio is intentionally stopped).
/// When audio coexistence is needed, use CoreAudioTransport instead.
///
/// Evidence: `og_source/generic/USB/ApoUSB.cpp` — IOUSBDeviceInterface245 usage
/// Evidence: IORegistry shows `UsbExclusiveOwner = "usbaudiod"` on all interfaces

#if canImport(IOUSBHost)
import IOKit
import IOKit.usb
import Foundation

// MARK: - IOUSBLib UUID Constants

/// These UUIDs are defined as macros in IOUSBLib.h and can't be imported by Swift.
nonisolated(unsafe) private let kIOUSBDeviceUserClientTypeUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
    0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)!

nonisolated(unsafe) private let kIOCFPlugInInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)!

nonisolated(unsafe) private let kIOUSBDeviceInterfaceID245UUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xFE, 0x2F, 0xD5, 0x2F, 0x3B, 0x5A, 0x47, 0x3B,
    0x97, 0x7B, 0xAD, 0x99, 0x00, 0x1E, 0xB3, 0xED)!

// MARK: - IOUSBLib Transport

/// USB transport using IOUSBDeviceInterface245 (legacy C API).
///
/// WARNING: Opening this transport WILL disrupt audio streaming because usbaudiod
/// exclusively owns all USB interfaces. Use only when audio interruption is acceptable
/// (firmware update, diagnostics, or explicit user action like "Initialize Hardware").
///
/// For normal operation, the app should detect the device via IOKit matching
/// (markAvailable) and send controls through CoreAudio custom properties.
public final class IOUSBHostTransport: USBTransport, @unchecked Sendable {
    private let lock = NSLock()

    /// The IOUSBDeviceInterface245 double-pointer (COM-style interface).
    private var deviceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface245>?>?

    /// Whether the device interface is currently open.
    private var deviceOpen: Bool = false

    /// Whether the device was found (may or may not be open).
    private var deviceAvailable: Bool = false

    /// The device identifier this transport is connected to.
    public let deviceIdentifier: USBDeviceIdentifier

    /// Whether the transport has a reachable device.
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deviceAvailable
    }

    /// Whether the transport currently holds an open USB device handle.
    public var hasOpenHandle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deviceOpen
    }

    /// Completion timeout for USB control transfers (seconds).
    public var completionTimeout: TimeInterval = 5.0

    /// Create a transport for the given device identifier.
    public init(deviceIdentifier: USBDeviceIdentifier) {
        self.deviceIdentifier = deviceIdentifier
    }

    deinit {
        closeSync()
    }

    // MARK: - Open / Close

    /// Open the USB device using IOUSBDeviceInterface245.
    ///
    /// WARNING: This claims the device and may disrupt audio streaming.
    /// Only call when audio interruption is acceptable.
    public func open() throws {
        let service = try findDevice()
        defer { IOObjectRelease(service) }

        // Step 1: Get the plugin interface
        var plugInInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0

        let kr = IOCreatePlugInInterfaceForService(
            service,
            kIOUSBDeviceUserClientTypeUUID,
            kIOCFPlugInInterfaceUUID,
            &plugInInterface,
            &score
        )

        guard kr == kIOReturnSuccess, let plugInInterface else {
            throw USBTransportError.ioError(kr)
        }

        // Step 2: Query for IOUSBDeviceInterface245
        var usbDevicePtr: UnsafeMutableRawPointer?
        let queryResult = plugInInterface.pointee?.pointee.QueryInterface(
            plugInInterface,
            CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID245UUID),
            &usbDevicePtr
        )

        IODestroyPlugInInterface(plugInInterface)

        guard queryResult == S_OK, let usbDevicePtr else {
            throw USBTransportError.ioError(Int32(queryResult ?? -1))
        }

        let devIface = usbDevicePtr.assumingMemoryBound(
            to: UnsafeMutablePointer<IOUSBDeviceInterface245>?.self
        )

        guard let vt = devIface.pointee else {
            throw USBTransportError.ioError(Int32(kIOReturnError))
        }

        // Step 3: Open — try normal first, then seize if another driver has it
        var openResult = vt.pointee.USBDeviceOpen(devIface)

        if openResult == kIOReturnExclusiveAccess {
            openResult = vt.pointee.USBDeviceOpenSeize(devIface)
        }

        if openResult != kIOReturnSuccess {
            _ = vt.pointee.Release(devIface)
            throw USBTransportError.ioError(openResult)
        }

        lock.lock()
        self.deviceInterface = devIface
        self.deviceOpen = true
        self.deviceAvailable = true
        lock.unlock()
    }

    /// Close the connection and mark device as unavailable.
    public func close() async {
        closeSync()
    }

    /// Synchronous close — marks device as unavailable (full disconnect).
    public func closeSync() {
        lock.lock()
        let devIface = deviceInterface
        let wasOpen = deviceOpen
        deviceInterface = nil
        deviceOpen = false
        deviceAvailable = false
        lock.unlock()

        if let devIface, let vt = devIface.pointee {
            if wasOpen {
                _ = vt.pointee.USBDeviceClose(devIface)
            }
            _ = vt.pointee.Release(devIface)
        }
    }

    /// Release the USB device handle without marking the device as unavailable.
    public func releaseHandle() {
        lock.lock()
        let devIface = deviceInterface
        let wasOpen = deviceOpen
        deviceInterface = nil
        deviceOpen = false
        lock.unlock()

        if let devIface, let vt = devIface.pointee {
            if wasOpen {
                _ = vt.pointee.USBDeviceClose(devIface)
            }
            _ = vt.pointee.Release(devIface)
        }
    }

    /// Mark the device as available without opening it.
    ///
    /// Used when we detect the device via IOKit matching but don't want to
    /// open it (to avoid disrupting the audio driver).
    public func markAvailable() {
        lock.lock()
        deviceAvailable = true
        lock.unlock()
    }

    // MARK: - USBTransport

    /// Send a vendor-specific USB control transfer.
    ///
    /// If the handle was released, auto-reopens, sends, then releases again.
    /// WARNING: Each auto-reopen may briefly disrupt audio.
    public func send(_ request: USBControlRequest) async throws -> USBControlResponse {
        guard request.data.count <= USBControlRequest.maxPayloadSize else {
            throw USBTransportError.payloadTooLarge(
                size: request.data.count,
                max: USBControlRequest.maxPayloadSize
            )
        }

        // Auto-open if handle was released (transactional mode)
        var autoOpened = false
        if !hasDeviceInterface() {
            guard isDeviceAvailable() else {
                throw USBTransportError.noDevice
            }
            try open()
            autoOpened = true
        }
        defer {
            if autoOpened {
                releaseHandle()
            }
        }

        guard hasDeviceInterface() else {
            throw USBTransportError.noDevice
        }

        // Build IOUSBDevRequest
        var usbRequest = IOUSBDevRequest()
        usbRequest.bmRequestType = request.bmRequestType
        usbRequest.bRequest = request.request
        usbRequest.wValue = request.value
        usbRequest.wIndex = request.index

        if request.direction == .read {
            let length = request.data.count
            usbRequest.wLength = UInt16(length)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(length, 1))
            buffer.initialize(repeating: 0, count: max(length, 1))
            defer { buffer.deallocate() }
            usbRequest.pData = UnsafeMutableRawPointer(buffer)

            let result = sendDeviceRequest(&usbRequest)
            if result != kIOReturnSuccess {
                throw mapIOReturnToError(result)
            }

            let bytesTransferred = Int(usbRequest.wLenDone)
            let responseData = Data(bytes: buffer, count: length)
            return USBControlResponse(data: responseData, bytesTransferred: bytesTransferred)
        } else {
            let length = request.data.count
            usbRequest.wLength = UInt16(length)

            if length > 0 {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
                defer { buffer.deallocate() }
                request.data.copyBytes(to: buffer, count: length)
                usbRequest.pData = UnsafeMutableRawPointer(buffer)

                let result = sendDeviceRequest(&usbRequest)
                if result != kIOReturnSuccess {
                    throw mapIOReturnToError(result)
                }

                return USBControlResponse(data: Data(), bytesTransferred: Int(usbRequest.wLenDone))
            } else {
                usbRequest.pData = nil
                let result = sendDeviceRequest(&usbRequest)
                if result != kIOReturnSuccess {
                    throw mapIOReturnToError(result)
                }
                return USBControlResponse(data: Data(), bytesTransferred: 0)
            }
        }
    }

    /// Send a device request with retry logic.
    private func sendDeviceRequest(_ request: UnsafeMutablePointer<IOUSBDevRequest>) -> IOReturn {
        lock.lock()
        let devIface = deviceInterface
        lock.unlock()

        guard let devIface, let vt = devIface.pointee else {
            return IOReturn(kIOReturnNoDevice)
        }

        var lastResult: IOReturn = IOReturn(kIOReturnError)
        let maxRetries = 3

        for attempt in 0..<maxRetries {
            lastResult = vt.pointee.DeviceRequest(devIface, request)
            if lastResult == kIOReturnSuccess {
                return lastResult
            }

            if lastResult == IOReturn(kIOReturnNoDevice) ||
               lastResult == IOReturn(kIOReturnNotResponding) {
                return lastResult
            }

            if attempt < maxRetries - 1 {
                usleep(1000)
            }
        }

        return lastResult
    }

    /// Map IOReturn codes to our error types.
    private func mapIOReturnToError(_ code: IOReturn) -> USBTransportError {
        // IOReturn is a signed Int32; the 0xE000_… IOKit codes have the high bit
        // set, so comparing a sign-extended Int(code) against positive literals
        // never matches. Compare the raw bit patterns against the IOReturn directly.
        switch code {
        case IOReturn(bitPattern: 0xE000_4007), IOReturn(bitPattern: 0xE000_5000):
            return .pipeStalled
        case IOReturn(bitPattern: 0xE000_4097), IOReturn(bitPattern: 0xE000_02D6):
            return .timeout
        case IOReturn(bitPattern: 0xE000_02ED):
            return .transactionError
        case IOReturn(bitPattern: 0xE000_0001):
            return .disconnected
        case IOReturn(kIOReturnNoDevice):
            return .noDevice
        default:
            return .ioError(Int32(truncatingIfNeeded: code))
        }
    }

    // MARK: - Device Discovery

    /// Find the IOService for our device by VID/PID.
    private func findDevice() throws -> io_service_t {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = Int(deviceIdentifier.vendorID)
        matching["idProduct"] = Int(deviceIdentifier.productID)

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            throw USBTransportError.noDevice
        }
        return service
    }

    private func hasDeviceInterface() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deviceInterface != nil && deviceOpen
    }

    private func isDeviceAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deviceAvailable
    }

    // MARK: - Reconnection

    /// Probe whether the USB control endpoint is responsive.
    public func probeConnection() async -> Bool {
        let probe = USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.symphonyIOVersion.rawValue,
            data: Data(count: 4)
        )
        do {
            _ = try await send(probe)
            return true
        } catch {
            return false
        }
    }

    /// Close and re-open the transport.
    public func reconnect() async -> Bool {
        closeSync()
        try? await Task.sleep(for: .milliseconds(2000))

        do {
            try open()
        } catch {
            return false
        }

        let responsive = await probeConnection()
        if responsive {
            releaseHandle()
        }
        return responsive
    }
}

// MARK: - IOUSBHost Device Discovery

/// Discovers Apogee Symphony IO devices using IOKit service matching.
public final class IOUSBHostDiscovery: DeviceDiscovery, @unchecked Sendable {
    private let lock = NSLock()
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var eventContinuation: AsyncStream<DeviceDiscoveryEvent>.Continuation?
    public let events: AsyncStream<DeviceDiscoveryEvent>

    public init() {
        var cont: AsyncStream<DeviceDiscoveryEvent>.Continuation!
        self.events = AsyncStream { continuation in
            cont = continuation
        }
        self.eventContinuation = cont
    }

    deinit {
        stopMonitoringSync()
    }

    public func scan() async throws -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        for pid in ApogeeUSB.SymphonyIO.allProductIDs {
            let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            matching["idVendor"] = Int(ApogeeUSB.vendorID)
            matching["idProduct"] = Int(pid)

            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            guard result == kIOReturnSuccess else { continue }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != IO_OBJECT_NULL {
                if let device = makeDiscoveredDevice(from: service, productID: pid) {
                    devices.append(device)
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }
        return devices
    }

    public func startMonitoring() async throws {
        try startMonitoringSync()
    }

    private func startMonitoringSync() throws {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { throw USBTransportError.ioError(-1) }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        lock.lock()
        self.notificationPort = port
        lock.unlock()

        for pid in ApogeeUSB.SymphonyIO.allProductIDs {
            try registerNotifications(port: port, productID: pid)
        }
    }

    public func stopMonitoring() async {
        stopMonitoringSync()
    }

    private func stopMonitoringSync() {
        lock.lock()
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        let port = notificationPort
        notificationPort = nil
        lock.unlock()
        if let port { IONotificationPortDestroy(port) }
    }

    private func registerNotifications(port: IONotificationPortRef, productID: UInt16) throws {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = Int(ApogeeUSB.vendorID)
        matching["idProduct"] = Int(productID)
        let context = Unmanaged.passUnretained(self).toOpaque()

        var addIter: io_iterator_t = 0
        let addResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matching as CFDictionary,
            { context, iterator in
                guard let context else { return }
                Unmanaged<IOUSBHostDiscovery>.fromOpaque(context)
                    .takeUnretainedValue().handleDeviceAdded(iterator: iterator)
            }, context, &addIter
        )
        guard addResult == kIOReturnSuccess else { throw USBTransportError.ioError(addResult) }
        drainIterator(addIter)
        lock.lock(); addedIterator = addIter; lock.unlock()

        let matchingRemove = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matchingRemove["idVendor"] = Int(ApogeeUSB.vendorID)
        matchingRemove["idProduct"] = Int(productID)

        var removeIter: io_iterator_t = 0
        let removeResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matchingRemove as CFDictionary,
            { context, iterator in
                guard let context else { return }
                Unmanaged<IOUSBHostDiscovery>.fromOpaque(context)
                    .takeUnretainedValue().handleDeviceRemoved(iterator: iterator)
            }, context, &removeIter
        )
        guard removeResult == kIOReturnSuccess else { throw USBTransportError.ioError(removeResult) }
        drainIterator(removeIter)
        lock.lock(); removedIterator = removeIter; lock.unlock()
    }

    private func handleDeviceAdded(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            if let device = makeDiscoveredDevice(from: service, productID: nil) {
                eventContinuation?.yield(.deviceAdded(device))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func handleDeviceRemoved(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            let uid = getDeviceUID(from: service) ?? "unknown"
            eventContinuation?.yield(.deviceRemoved(deviceUID: uid))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func drainIterator(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func makeDiscoveredDevice(from service: io_service_t, productID: UInt16?) -> DiscoveredDevice? {
        let pid: UInt16
        if let productID {
            pid = productID
        } else {
            guard let props = getServiceProperties(service),
                  let pidVal = props["idProduct"] as? Int else { return nil }
            pid = UInt16(pidVal)
        }

        let uid = getDeviceUID(from: service) ?? "usb-\(pid)-\(service)"
        guard let identifier = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID, productID: pid, deviceUID: uid
        ) else { return nil }

        let name: String
        switch identifier.mode {
        case .channels32: name = "Symphony I/O (32-Channel)"
        case .channels16: name = "Symphony I/O (16-Channel)"
        case .channels8:  name = "Symphony I/O (8-Channel)"
        }
        return DiscoveredDevice(usbIdentifier: identifier, name: name)
    }

    private func getDeviceUID(from service: io_service_t) -> String? {
        guard let props = getServiceProperties(service) else { return nil }
        if let serial = props["USB Serial Number"] as? String { return serial }
        if let locationID = props["locationID"] as? Int { return "usb-location-\(locationID)" }
        return nil
    }

    private func getServiceProperties(_ service: io_service_t) -> NSDictionary? {
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0)
        guard result == kIOReturnSuccess, let props = propertiesRef?.takeRetainedValue() else { return nil }
        return props as NSDictionary
    }
}

#endif // canImport(IOUSBHost)
