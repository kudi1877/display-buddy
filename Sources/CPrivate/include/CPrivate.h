#ifndef CPRIVATE_H
#define CPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// Private IOKit functions used on Apple Silicon to talk DDC/CI to external
// monitors. They have been stable since macOS 11 and are used by
// MonitorControl, Lunar and m1ddc.
typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

#endif
