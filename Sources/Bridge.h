#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// Private IOKit HID API used to read Apple Silicon temperature sensors.
// Implicit bridging lets Swift manage the +1 reference returned by the Copy
// call.
CF_ASSUME_NONNULL_BEGIN
CF_IMPLICIT_BRIDGING_ENABLED

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(
    IOHIDServiceClientRef service, int64_t type, int32_t options,
    int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

CF_IMPLICIT_BRIDGING_DISABLED
CF_ASSUME_NONNULL_END
