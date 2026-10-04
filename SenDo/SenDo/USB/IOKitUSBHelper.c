#include "IOKitUSBHelper.h"

// Helper macro to cast void* to IOUSBDeviceInterface**
#define CAST_DEVICE(x) ((IOUSBDeviceInterface**)(x))
// Helper macro to cast void* to IOUSBInterfaceInterface**
#define CAST_INTERFACE(x) ((IOUSBInterfaceInterface**)(x))

IOReturn SenDo_CreateUSBDeviceInterface(
    io_service_t service,
    void **outDeviceInterface
) {
    IOCFPlugInInterface **pluginInterface = NULL;
    SInt32 score = 0;
    
    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &pluginInterface,
        &score
    );
    
    if (kr != KERN_SUCCESS || !pluginInterface) {
        return kr;
    }
    
    IOUSBDeviceInterface **deviceInterface = NULL;
    kr = (*pluginInterface)->QueryInterface(
        pluginInterface,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
        (LPVOID *)&deviceInterface
    );
    
    (*pluginInterface)->Release(pluginInterface);
    
    if (kr == KERN_SUCCESS && deviceInterface) {
        *outDeviceInterface = deviceInterface;
    }
    
    return kr;
}

IOReturn SenDo_USBDeviceOpen(void *deviceInterface) {
    if (!deviceInterface) return kIOReturnBadArgument;
    return (*CAST_DEVICE(deviceInterface))->USBDeviceOpen(CAST_DEVICE(deviceInterface));
}

IOReturn SenDo_USBDeviceClose(void *deviceInterface) {
    if (!deviceInterface) return kIOReturnBadArgument;
    return (*CAST_DEVICE(deviceInterface))->USBDeviceClose(CAST_DEVICE(deviceInterface));
}

IOReturn SenDo_USBSetConfiguration(void *deviceInterface, UInt8 configValue) {
    if (!deviceInterface) return kIOReturnBadArgument;
    return (*CAST_DEVICE(deviceInterface))->SetConfiguration(CAST_DEVICE(deviceInterface), configValue);
}

IOReturn SenDo_CreateInterfaceIterator(
    void *deviceInterface,
    IOUSBFindInterfaceRequest *request,
    io_iterator_t *outIterator
) {
    if (!deviceInterface) return kIOReturnBadArgument;
    return (*CAST_DEVICE(deviceInterface))->CreateInterfaceIterator(CAST_DEVICE(deviceInterface), request, outIterator);
}

IOReturn SenDo_CreateUSBInterfaceInterface(
    io_service_t service,
    void **outInterfaceInterface
) {
    IOCFPlugInInterface **pluginInterface = NULL;
    SInt32 score = 0;
    
    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &pluginInterface,
        &score
    );
    
    if (kr != KERN_SUCCESS || !pluginInterface) {
        return kr;
    }
    
    IOUSBInterfaceInterface **ifaceInterface = NULL;
    kr = (*pluginInterface)->QueryInterface(
        pluginInterface,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
        (LPVOID *)&ifaceInterface
    );
    
    (*pluginInterface)->Release(pluginInterface);
    
    if (kr == KERN_SUCCESS && ifaceInterface) {
        *outInterfaceInterface = ifaceInterface;
    }
    
    return kr;
}

IOReturn SenDo_GetNumEndpoints(
    void *ifaceInterface,
    UInt8 *outNumEndpoints
) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    UInt8 numEndpoints = 0;
    IOReturn result = (*CAST_INTERFACE(ifaceInterface))->GetNumEndpoints(CAST_INTERFACE(ifaceInterface), &numEndpoints);
    if (result == KERN_SUCCESS) {
        *outNumEndpoints = numEndpoints;
    }
    return result;
}

IOReturn SenDo_GetPipeProperties(
    void *ifaceInterface,
    UInt8 pipeRef,
    UInt8 *outDirection,
    UInt8 *outNumber,
    UInt8 *outTransferType,
    UInt16 *outMaxPacketSize,
    UInt8 *outInterval
) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->GetPipeProperties(
        CAST_INTERFACE(ifaceInterface), pipeRef,
        outDirection, outNumber, outTransferType,
        outMaxPacketSize, outInterval
    );
}

IOReturn SenDo_WritePipe(
    void *ifaceInterface,
    UInt8 pipeRef,
    const void *data,
    UInt32 size
) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->WritePipe(CAST_INTERFACE(ifaceInterface), pipeRef, (void *)data, size);
}

IOReturn SenDo_ReadPipe(
    void *ifaceInterface,
    UInt8 pipeRef,
    void *data,
    UInt32 *ioSize
) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->ReadPipe(CAST_INTERFACE(ifaceInterface), pipeRef, data, ioSize);
}

IOReturn SenDo_ReadPipeAsync(
    void *ifaceInterface,
    UInt8 pipeRef,
    void *data,
    UInt32 size,
    void (*callback)(void *refcon, IOReturn result, void *arg0),
    void *refcon
) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    if (!callback) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->ReadPipeAsync(
        CAST_INTERFACE(ifaceInterface), pipeRef, data, size, callback, refcon
    );
}

IOReturn SenDo_AbortPipe(void *ifaceInterface, UInt8 pipeRef) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->AbortPipe(CAST_INTERFACE(ifaceInterface), pipeRef);
}

IOReturn SenDo_AttachInterfaceAsyncEventSource(void *ifaceInterface) {
    if (!ifaceInterface) return kIOReturnBadArgument;

    CFRunLoopSourceRef source = NULL;
    IOReturn kr = (*CAST_INTERFACE(ifaceInterface))->CreateInterfaceAsyncEventSource(
        CAST_INTERFACE(ifaceInterface), &source
    );
    if (kr != KERN_SUCCESS) {
        return kr;
    }
    if (!source) {
        return kIOReturnError;
    }

    // Schedule on THIS thread's run loop — the caller must run it afterwards.
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRelease(source); // the run loop now owns it
    return KERN_SUCCESS;
}

IOReturn SenDo_ClaimInterface(void *ifaceInterface) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->USBInterfaceOpen(CAST_INTERFACE(ifaceInterface));
}

IOReturn SenDo_ReleaseInterface(void *ifaceInterface) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->USBInterfaceClose(CAST_INTERFACE(ifaceInterface));
}

IOReturn SenDo_SetAlternateInterface(void *ifaceInterface, UInt8 alternateSetting) {
    if (!ifaceInterface) return kIOReturnBadArgument;
    return (*CAST_INTERFACE(ifaceInterface))->SetAlternateInterface(CAST_INTERFACE(ifaceInterface), alternateSetting);
}

void SenDo_ReleaseUSBDeviceInterface(void *deviceInterface) {
    if (deviceInterface) {
        (*CAST_DEVICE(deviceInterface))->Release(CAST_DEVICE(deviceInterface));
    }
}

void SenDo_ReleaseUSBInterfaceInterface(void *ifaceInterface) {
    if (ifaceInterface) {
        (*CAST_INTERFACE(ifaceInterface))->Release(CAST_INTERFACE(ifaceInterface));
    }
}
