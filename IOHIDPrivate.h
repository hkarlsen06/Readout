// Private IOKit HID calls used to read the SoC temperature sensors (no public API exists).
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
CFTypeRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(CFTypeRef, int32_t);
