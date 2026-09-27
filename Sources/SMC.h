#include <stdint.h>

// AppleSMC user-client struct (IOConnectCallStructMethod selector 2). Declared
// in C so the 80-byte kernel layout, including padding, is guaranteed.
typedef struct {
  uint8_t major, minor, build, reserved;
  uint16_t release;
} SMCVersion;

typedef struct {
  uint16_t version, length;
  uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
  uint32_t dataSize;
  uint32_t dataType;
  uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
  uint32_t key;
  SMCVersion vers;
  SMCPLimitData pLimitData;
  SMCKeyInfo keyInfo;
  uint8_t result, status, data8;
  uint32_t data32;
  uint8_t bytes[32];
} SMCParam;
