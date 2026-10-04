#ifndef IOKitUSBHelper_h
#define IOKitUSBHelper_h

#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

// Use opaque types that Swift can safely bridge
typedef struct OpaqueIOUSBDeviceInterface OpaqueIOUSBDeviceInterface;
typedef struct OpaqueIOUSBInterfaceInterface OpaqueIOUSBInterfaceInterface;

// Create a USB device interface from an io_service_t
// Returns KERN_SUCCESS on success, caller must release the returned interface
IOReturn SenDo_CreateUSBDeviceInterface(
    io_service_t service,
    void **outDeviceInterface
);

// Open a USB device
IOReturn SenDo_USBDeviceOpen(void *deviceInterface);

// Close a USB device
IOReturn SenDo_USBDeviceClose(void *deviceInterface);

// Set USB configuration
IOReturn SenDo_USBSetConfiguration(void *deviceInterface, UInt8 configValue);

// Create an interface iterator
IOReturn SenDo_CreateInterfaceIterator(
    void *deviceInterface,
    IOUSBFindInterfaceRequest *request,
    io_iterator_t *outIterator
);

// Create a USB interface interface from an io_service_t
IOReturn SenDo_CreateUSBInterfaceInterface(
    io_service_t service,
    void **outInterfaceInterface
);

// Get number of endpoints
IOReturn SenDo_GetNumEndpoints(
    void *ifaceInterface,
    UInt8 *outNumEndpoints
);

// Get pipe properties
IOReturn SenDo_GetPipeProperties(
    void *ifaceInterface,
    UInt8 pipeRef,
    UInt8 *outDirection,
    UInt8 *outNumber,
    UInt8 *outTransferType,
    UInt16 *outMaxPacketSize,
    UInt8 *outInterval
);

// Write data to a pipe
IOReturn SenDo_WritePipe(
    void *ifaceInterface,
    UInt8 pipeRef,
    const void *data,
    UInt32 size
);

// Read data from a pipe
IOReturn SenDo_ReadPipe(
    void *ifaceInterface,
    UInt8 pipeRef,
    void *data,
    UInt32 *ioSize
);

// Read data from a pipe asynchronously.
// `callback` matches IOAsyncCallback1 exactly:
//   void (*)(void *refcon, IOReturn result, void *arg0)
// where arg0 carries the number of bytes actually transferred
// (recover it with (size_t)arg0).
// The callback is invoked once, on the async completion port.
IOReturn SenDo_ReadPipeAsync(
    void *ifaceInterface,
    UInt8 pipeRef,
    void *data,
    UInt32 size,
    void (*callback)(void *refcon, IOReturn result, void *arg0),
    void *refcon
);

// Abort any outstanding transactions on a pipe.
// The pipe stays usable afterwards (unlike a stall, which needs ClearPipe).
IOReturn SenDo_AbortPipe(
    void *ifaceInterface,
    UInt8 pipeRef
);

// Wraps the interface's async completion Mach port in a CFRunLoopSource and
// schedules it on the run loop of the CALLING thread.
// Without this, ReadPipeAsync fails immediately with kIOUSBNoAsyncPortErr
// (0xE000405F, "no async port").
// The calling thread must subsequently run that run loop (CFRunLoopRun) or
// completions will never be delivered.
IOReturn SenDo_AttachInterfaceAsyncEventSource(void *ifaceInterface);

// Release a USB device interface
void SenDo_ReleaseUSBDeviceInterface(void *deviceInterface);

// Release a USB interface interface
void SenDo_ReleaseUSBInterfaceInterface(void *ifaceInterface);

// Claim an interface (required before setting alternate interface or using pipes)
IOReturn SenDo_ClaimInterface(void *ifaceInterface);

// Release claimed interface
IOReturn SenDo_ReleaseInterface(void *ifaceInterface);

// Set alternate interface (wrapper for IOKit)
IOReturn SenDo_SetAlternateInterface(void *ifaceInterface, UInt8 alternateSetting);

#endif
