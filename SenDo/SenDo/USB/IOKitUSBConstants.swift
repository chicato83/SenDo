import Foundation
import IOKit
import IOKit.usb
import CoreFoundation

// MARK: - IOKit USB Constants

// These constants are defined as #define macros in C headers that Swift cannot import.
// We recreate them here using CFUUIDGetConstantUUIDWithBytes.

/// UUID: 9dc7b780-9ec0-11D4-a54f-000a27052861
let kIOUSBDeviceUserClientTypeIDRef: CFUUID = {
    let bytes: [UInt8] = [
        0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
        0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61
    ]
    return bytes.withUnsafeBufferPointer { ptr in
        CFUUIDGetConstantUUIDWithBytes(nil,
            ptr[0], ptr[1], ptr[2], ptr[3],
            ptr[4], ptr[5], ptr[6], ptr[7],
            ptr[8], ptr[9], ptr[10], ptr[11],
            ptr[12], ptr[13], ptr[14], ptr[15]
        )
    }
}()

/// UUID: C244E858-109C-11D4-91D4-0050E4C6426F
let kIOCFPlugInInterfaceIDRef: CFUUID = {
    let bytes: [UInt8] = [
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
    ]
    return bytes.withUnsafeBufferPointer { ptr in
        CFUUIDGetConstantUUIDWithBytes(nil,
            ptr[0], ptr[1], ptr[2], ptr[3],
            ptr[4], ptr[5], ptr[6], ptr[7],
            ptr[8], ptr[9], ptr[10], ptr[11],
            ptr[12], ptr[13], ptr[14], ptr[15]
        )
    }
}()

/// UUID: 2d9786c6-9ef3-11D4-ad51-000a27052861
let kIOUSBInterfaceUserClientTypeIDRef: CFUUID = {
    let bytes: [UInt8] = [
        0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4,
        0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61
    ]
    return bytes.withUnsafeBufferPointer { ptr in
        CFUUIDGetConstantUUIDWithBytes(nil,
            ptr[0], ptr[1], ptr[2], ptr[3],
            ptr[4], ptr[5], ptr[6], ptr[7],
            ptr[8], ptr[9], ptr[10], ptr[11],
            ptr[12], ptr[13], ptr[14], ptr[15]
        )
    }
}()

/// UUID: 3C9EE1EB-2402-11B2-8E7E-000A27801E86
let kIOUSBDeviceInterfaceID187Ref: CFUUID = {
    let bytes: [UInt8] = [
        0x3C, 0x9E, 0xE1, 0xEB, 0x24, 0x02, 0x11, 0xB2,
        0x8E, 0x7E, 0x00, 0x0A, 0x27, 0x80, 0x1E, 0x86
    ]
    return bytes.withUnsafeBufferPointer { ptr in
        CFUUIDGetConstantUUIDWithBytes(nil,
            ptr[0], ptr[1], ptr[2], ptr[3],
            ptr[4], ptr[5], ptr[6], ptr[7],
            ptr[8], ptr[9], ptr[10], ptr[11],
            ptr[12], ptr[13], ptr[14], ptr[15]
        )
    }
}()

/// UUID: C63D3C92-0884-11D7-9692-0003933E3E3E
let kIOUSBInterfaceInterfaceID197Ref: CFUUID = {
    let bytes: [UInt8] = [
        0xC6, 0x3D, 0x3C, 0x92, 0x08, 0x84, 0x11, 0xD7,
        0x96, 0x92, 0x00, 0x03, 0x93, 0x3E, 0x3E, 0x3E
    ]
    return bytes.withUnsafeBufferPointer { ptr in
        CFUUIDGetConstantUUIDWithBytes(nil,
            ptr[0], ptr[1], ptr[2], ptr[3],
            ptr[4], ptr[5], ptr[6], ptr[7],
            ptr[8], ptr[9], ptr[10], ptr[11],
            ptr[12], ptr[13], ptr[14], ptr[15]
        )
    }
}()
