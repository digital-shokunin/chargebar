// smc-probe: READ-ONLY dump of charge-related SMC keys on Apple silicon.
//
// Uses only the AppleSMC "read key", "get key info" and "get key from index"
// commands. There is deliberately no write path in this file.
//
//   clang -O2 -framework IOKit -o build/smc-probe tools/smc-probe.c
//   build/smc-probe            # charge-related keys
//   build/smc-probe --all      # every key (name, type, size)

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

typedef struct {
    char major, minor, build, reserved;
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
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData layout must match the kernel's 80-byte struct");

static io_connect_t conn;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static kern_return_t call(SMCKeyData *in, SMCKeyData *out) {
    // Only read-class commands are ever issued.
    if (in->data8 != kSMCReadKey && in->data8 != kSMCGetKeyInfo && in->data8 != kSMCGetKeyFromIndex) {
        return kIOReturnNotPermitted;
    }
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(*in), out, &outSize);
}

static int keyInfo(uint32_t key, SMCKeyInfo *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (call(&in, &out) != kIOReturnSuccess || out.result != 0) return -1;
    *info = out.keyInfo;
    return 0;
}

static int readKey(uint32_t key, SMCKeyInfo *info, uint8_t bytes[32]) {
    if (keyInfo(key, info) != 0) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = kSMCReadKey;
    if (call(&in, &out) != kIOReturnSuccess || out.result != 0) return -2;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

static void printKey(const char *name) {
    SMCKeyInfo info;
    uint8_t bytes[32];
    int rc = readKey(fourcc(name), &info, bytes);
    if (rc == -1) { printf("%-4s  (absent)\n", name); return; }
    char type[5];
    unfourcc(info.dataType, type);
    if (rc == -2) { printf("%-4s  type=%-4s size=%u attr=0x%02x  (read failed)\n", name, type, info.dataSize, info.dataAttributes); return; }
    printf("%-4s  type=%-4s size=%u attr=0x%02x  bytes=", name, type, info.dataSize, info.dataAttributes);
    for (uint32_t i = 0; i < info.dataSize && i < 32; i++) printf("%02x", bytes[i]);
    printf("\n");
}

static int isChargeRelated(const char *k) {
    static const char *exact[] = {"BCLM", "CHWA", "CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "CH0K", "ACLC", "AC-W", "BFCL", NULL};
    for (int i = 0; exact[i]; i++) if (strncmp(k, exact[i], 4) == 0) return 1;
    return k[0] == 'C' && k[1] == 'H';  // the CH** charger family
}

int main(int argc, char **argv) {
    int all = argc > 1 && strcmp(argv[1], "--all") == 0;

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "AppleSMC service not found\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "IOServiceOpen failed: 0x%x\n", kr); return 1; }

    SMCKeyInfo countInfo;
    uint8_t countBytes[32];
    uint32_t count = 0;
    if (readKey(fourcc("#KEY"), &countInfo, countBytes) == 0) {
        count = ((uint32_t)countBytes[0] << 24) | ((uint32_t)countBytes[1] << 16) | ((uint32_t)countBytes[2] << 8) | countBytes[3];
    }
    printf("# SMC keys: %u\n", count);

    // Named candidates first, present or not.
    const char *candidates[] = {"BCLM", "CHWA", "CH0B", "CH0C", "CHTE", "CH0I", "CHIE", "CH0J", "CH0K", "ACLC", NULL};
    printf("# candidates\n");
    for (int i = 0; candidates[i]; i++) printKey(candidates[i]);

    printf("# %s\n", all ? "all keys" : "all charge-related keys present");
    for (uint32_t i = 0; i < count; i++) {
        SMCKeyData in = {0}, out = {0};
        in.data8 = kSMCGetKeyFromIndex;
        in.data32 = i;
        if (call(&in, &out) != kIOReturnSuccess || out.result != 0) continue;
        char name[5];
        unfourcc(out.key, name);
        if (all || isChargeRelated(name)) printKey(name);
    }

    IOServiceClose(conn);
    return 0;
}
