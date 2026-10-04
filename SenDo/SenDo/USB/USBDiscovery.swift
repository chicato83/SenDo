import Foundation
import IOKit
import IOKit.usb

// MARK: - USB Device Discovery

/// Discovers Nintendo Switch connected via USB
final class USBDiscovery: ObservableObject {
    @Published var isConnected = false
    @Published var deviceName: String = ""

    // Nintendo Switch USB identifiers
    private let nintendoVendorID: UInt32 = 0x057E
    private let switchProductID: UInt32 = 0x3000
    // Alternative: libnx USB comms
    private let libnxVendorID: UInt32 = 0x16C0
    private let libnxProductID: UInt32 = 0x27E2

    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminateIterator: io_iterator_t = 0

    var onDeviceConnected: ((USBDevice) -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    func start() {
        print("[SenDo] USBDiscovery.start() called")
        startMatching()
    }

    func stop() {
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if terminateIterator != 0 {
            IOObjectRelease(terminateIterator)
            terminateIterator = 0
        }
    }

    // MARK: - IOKit Matching

    private func startMatching() {
        print("[SenDo] startMatching() called")
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notificationPort else {
            SenDoLog.log("ERROR: Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(port)
        if let source = runLoopSource?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            SenDoLog.log("RunLoop source added")
        } else {
            SenDoLog.log("WARNING: No RunLoop source from notification port")
        }

        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)

        let matchedContext = Unmanaged.passUnretained(self).toOpaque()
        let matchedResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchingDict,
            deviceMatchedCallback,
            matchedContext,
            &matchedIterator
        )

        guard matchedResult == KERN_SUCCESS else {
            SenDoLog.log("Failed to add matching notification: \(matchedResult)")
            return
        }

        processMatchedDevices()

        let removedContext = Unmanaged.passUnretained(self).toOpaque()
        let removedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDict,
            deviceRemovedCallback,
            removedContext,
            &terminateIterator
        )

        guard removedResult == KERN_SUCCESS else {
            SenDoLog.log("Failed to add removal notification: \(removedResult)")
            return
        }

        SenDoLog.log("USB discovery started — watching for Nintendo Switch...")
    }

    private func processMatchedDevices() {
        var service = IOIteratorNext(matchedIterator)
        SenDoLog.log("processMatchedDevices: iterator returned \(service)")
        var count = 0
        while service != 0 {
            count += 1
            if let device = makeDevice(from: service) {
                SenDoLog.log("processMatchedDevices: found Switch! Dispatching connected...")
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.deviceName = device.name
                    self.onDeviceConnected?(device)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(matchedIterator)
        }
        SenDoLog.log("processMatchedDevices: scanned \(count) devices total")
    }

    internal func makeDevice(from service: io_service_t) -> USBDevice? {
        guard let props = properties(for: service) else {
            SenDoLog.log("makeDevice: no properties for service \(service)")
            return nil
        }

        let vid = props["idVendor"] as? UInt32 ?? 0
        let pid = props["idProduct"] as? UInt32 ?? 0
        let productName = props["USB Product Name"] as? String ?? "?"
        let manufacturer = props["Manufacturer"] as? String ?? "?"
        
        SenDoLog.log("makeDevice: VID=\(String(format: "0x%04X", vid)) PID=\(String(format: "0x%04X", pid)) name=\(productName) mfg=\(manufacturer)")

        let isSwitch = (vid == nintendoVendorID && pid == switchProductID)
        let isLibnx = (vid == libnxVendorID && pid == libnxProductID)

        guard isSwitch || isLibnx else { return nil }

        let name = props["USB Product Name"] as? String ?? "Nintendo Switch"
        let device = USBDevice(name: name, vendorID: vid, productID: pid, service: service)
        SenDoLog.log("makeDevice: *** FOUND SWITCH *** \(name) (VID: \(String(format: "0x%04X", vid)), PID: \(String(format: "0x%04X", pid)))")
        return device
    }

    private func properties(for service: io_service_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }
}

// MARK: - C Callbacks

private func deviceMatchedCallback(
    refCon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refCon = refCon else { return }
    let discovery = Unmanaged<USBDiscovery>.fromOpaque(refCon).takeUnretainedValue()

    var service = IOIteratorNext(iterator)
    while service != 0 {
        if let device = discovery.makeDevice(from: service) {
            DispatchQueue.main.async {
                discovery.isConnected = true
                discovery.deviceName = device.name
                discovery.onDeviceConnected?(device)
            }
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

private func deviceRemovedCallback(
    refCon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refCon = refCon else { return }
    let discovery = Unmanaged<USBDiscovery>.fromOpaque(refCon).takeUnretainedValue()

    var service = IOIteratorNext(iterator)
    while service != 0 {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }

    DispatchQueue.main.async {
        discovery.isConnected = false
        discovery.deviceName = ""
        discovery.onDeviceDisconnected?()
    }
}

// MARK: - USB Device

/// Represents a connected Nintendo Switch via IOKit
/// Uses C helper functions for IOKit USB operations (Swift cannot safely call C function pointers in structs)
final class USBDevice: @unchecked Sendable {
    let name: String
    let vendorID: UInt32
    let productID: UInt32

    private var retainedService: io_service_t
    private var deviceInterface: UnsafeMutableRawPointer?
    private var ifaceInterface: UnsafeMutableRawPointer?
    private var deviceIsOpen = false

    init(name: String, vendorID: UInt32, productID: UInt32, service: io_service_t) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.retainedService = service
        IOObjectRetain(service)
    }

    /// Open the device using C helper and find the matching USB interface
    func open() throws {
        guard deviceInterface == nil else { return }

        SenDoLog.log("Opening USB device: \(name)...")

        var devicePtr: UnsafeMutableRawPointer?
        let kr = SenDo_CreateUSBDeviceInterface(retainedService, &devicePtr)
        guard kr == KERN_SUCCESS, let device = devicePtr else {
            SenDoLog.log("Failed to create USB device interface: \(kr)")
            throw USBDeviceError.pluginCreationFailed(kr)
        }

        deviceInterface = device

        // Retry USBDeviceOpen with delay — the device may need time after appearing
        var openResult: IOReturn = kIOReturnNotReady
        for attempt in 1...3 {
            openResult = SenDo_USBDeviceOpen(device)
            if openResult == KERN_SUCCESS { break }
            SenDoLog.log("USBDeviceOpen attempt \(attempt) failed: \(openResult), retrying in 1s...")
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard openResult == KERN_SUCCESS else {
            SenDoLog.log("Failed to open USB device after retries: \(openResult)")
            throw USBDeviceError.openFailed(openResult)
        }
        SenDoLog.log("USB device opened successfully")

        // Set configuration (Switch needs this before interfaces are visible)
        let configResult = SenDo_USBSetConfiguration(device, 1)
        SenDoLog.log("SetConfiguration(1) result: \(configResult)")

        // Find the matching USB interface — all 4 fields must be set
        var request = IOUSBFindInterfaceRequest()
        request.bInterfaceClass = UInt16(kIOUSBFindInterfaceDontCare)
        request.bInterfaceSubClass = UInt16(kIOUSBFindInterfaceDontCare)
        request.bInterfaceProtocol = UInt16(kIOUSBFindInterfaceDontCare)
        request.bAlternateSetting = UInt16(kIOUSBFindInterfaceDontCare)
        SenDoLog.log("CreateInterfaceIterator: class=\(request.bInterfaceClass) sub=\(request.bInterfaceSubClass) proto=\(request.bInterfaceProtocol) alt=\(request.bAlternateSetting)")

        var iterator: io_iterator_t = 0
        let createResult = SenDo_CreateInterfaceIterator(device, &request, &iterator)
        SenDoLog.log("CreateInterfaceIterator result: \(createResult), iterator: \(iterator)")
        guard createResult == KERN_SUCCESS else {
            SenDoLog.log("Failed to create interface iterator: \(createResult)")
            throw USBDeviceError.interfaceIteratorFailed(createResult)
        }

        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else {
            SenDoLog.log("No matching USB interface found (iterator returned 0)")
            throw USBDeviceError.noMatchingInterface
        }
        SenDoLog.log("Found USB interface service: \(service)")

        // Create interface interface using C helper
        var ifacePtr: UnsafeMutableRawPointer?
        let createIfaceResult = SenDo_CreateUSBInterfaceInterface(service, &ifacePtr)
        IOObjectRelease(service)
        guard createIfaceResult == KERN_SUCCESS, let iface = ifacePtr else {
            SenDoLog.log("Failed to create USB interface: \(createIfaceResult)")
            throw USBDeviceError.interfaceCreationFailed(createIfaceResult)
        }

        ifaceInterface = iface

        // Open the interface for exclusive access (required before GetPipeProperties)
        let claimResult = SenDo_ClaimInterface(iface)
        SenDoLog.log("USBInterfaceOpen result: \(claimResult)")
        if claimResult != KERN_SUCCESS {
            SenDoLog.log("WARNING: USBInterfaceOpen failed: \(claimResult) — continuing anyway")
        }

        deviceIsOpen = true
        SenDoLog.log("USB device opened and interface found")
    }

    func close() {
        guard deviceIsOpen else { return }
        if let iface = ifaceInterface {
            SenDo_ReleaseInterface(iface)
            SenDo_ReleaseUSBInterfaceInterface(iface)
            ifaceInterface = nil
        }
        if let device = deviceInterface {
            SenDo_ReleaseUSBDeviceInterface(device)
            deviceInterface = nil
        }
        deviceIsOpen = false
    }

    func getRawDeviceInterface() -> UnsafeMutableRawPointer? {
        return deviceInterface
    }

    func getRawIfaceInterface() -> UnsafeMutableRawPointer? {
        return ifaceInterface
    }

    deinit {
        close()
        IOObjectRelease(retainedService)
    }
}

// MARK: - USB Device Error

enum USBDeviceError: LocalizedError {
    case pluginCreationFailed(kern_return_t)
    case queryInterfaceFailed(kern_return_t)
    case openFailed(kern_return_t)
    case interfaceIteratorFailed(kern_return_t)
    case noMatchingInterface
    case interfaceCreationFailed(kern_return_t)

    var errorDescription: String? {
        switch self {
        case .pluginCreationFailed(let code):
            return "Failed to create IOKit plugin: \(code)"
        case .queryInterfaceFailed(let code):
            return "Failed to query device interface: \(code)"
        case .openFailed(let code):
            return "Failed to open USB device: \(code)"
        case .interfaceIteratorFailed(let code):
            return "Failed to create interface iterator: \(code)"
        case .noMatchingInterface:
            return "No matching USB interface found"
        case .interfaceCreationFailed(let code):
            return "Failed to create USB interface: \(code)"
        }
    }
}
