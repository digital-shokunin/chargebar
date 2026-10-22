// chie-test: supervised one-shot test of SMC key CHIE (adapter disable) on Apple silicon.
//
// WRITES HARDWARE STATE. Run only with explicit intent, as root, while plugged in:
//
//   clang -O2 -Wall -framework IOKit -framework CoreFoundation -o build/chie-test tools/chie-test.c
//   sudo build/chie-test
//
// Steps: read CHIE -> check the adapter is actually powering the Mac -> write 0x08
// -> sample for 10 s -> restore the original value -> read back. The original
// value is also restored on SIGINT, SIGTERM, SIGHUP and normal exit.
//
// Live signals come from SMC keys (ioreg's battery values only refresh about once
// a minute): PDTR = DC-in power (W), PPBR = battery power (W), B0AC = battery
// current (mA, negative = discharging).
//
// PASS: before the write PDTR is well above 0 (adapter powering the Mac); while
// CHIE=0x08, PDTR drops to ~0 and B0AC goes negative with the adapter still
// connected; after restore PDTR comes back.
// The test refuses to start if the Mac is already running from battery (e.g.
// macOS draining down to its Charge Limit), since that would mask the result.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;
_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData layout");

static const uint32_t kCHIE = ('C' << 24) | ('H' << 16) | ('I' << 8) | 'E';
static const uint8_t kAdapterOff = 0x08;

static io_connect_t conn;
static int original = -1;     // CHIE value to restore; -1 until read
static volatile sig_atomic_t restored = 1;

static kern_return_t smcCall(SMCKeyData *in, SMCKeyData *out) {
    size_t size = sizeof(*out);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(*in), out, &size);
}

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

// Read-only helper for the live power keys.
static int readKey(const char *name, uint32_t expectSize, uint8_t out[32]) {
    SMCKeyData in = {0}, res = {0};
    in.key = fourcc(name);
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(&in, &res) != kIOReturnSuccess || res.result != 0 || res.keyInfo.dataSize != expectSize) return -1;
    memset(&in, 0, sizeof in);
    in.key = fourcc(name);
    in.keyInfo.dataSize = expectSize;
    in.data8 = kSMCReadKey;
    memset(&res, 0, sizeof res);
    if (smcCall(&in, &res) != kIOReturnSuccess || res.result != 0) return -1;
    memcpy(out, res.bytes, 32);
    return 0;
}

static float readFloat(const char *name) {
    uint8_t b[32];
    float f = -1;
    if (readKey(name, 4, b) == 0) memcpy(&f, b, 4);  // little-endian on Apple silicon
    return f;
}

static int readCurrent(void) {
    uint8_t b[32];
    int16_t v = 0;
    if (readKey("B0AC", 2, b) == 0) memcpy(&v, b, 2);
    return v;
}

static int readCHIE(uint8_t *value) {
    SMCKeyData in = {0}, out = {0};
    in.key = kCHIE;
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(&in, &out) != kIOReturnSuccess || out.result != 0 || out.keyInfo.dataSize != 1) return -1;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = kCHIE;
    in.keyInfo.dataSize = 1;
    in.data8 = kSMCReadKey;
    if (smcCall(&in, &out) != kIOReturnSuccess || out.result != 0) return -1;
    *value = out.bytes[0];
    return 0;
}

static int writeCHIE(uint8_t value) {
    SMCKeyData in = {0}, out = {0};
    in.key = kCHIE;
    in.keyInfo.dataSize = 1;
    in.data8 = kSMCWriteKey;
    in.bytes[0] = value;
    kern_return_t kr = smcCall(&in, &out);
    if (kr != kIOReturnSuccess || out.result != 0) {
        fprintf(stderr, "write CHIE=0x%02x failed: kr=0x%x result=%u\n", value, kr, out.result);
        return -1;
    }
    return 0;
}

static void restore(void) {
    if (restored || original < 0) return;
    if (writeCHIE((uint8_t)original) == 0) restored = 1;
    uint8_t v = 0xff;
    readCHIE(&v);
    fprintf(stderr, "restored CHIE -> 0x%02x (read back 0x%02x)\n", original, v);
}

static void onSignal(int sig) {
    restore();
    _exit(128 + sig);
}

static long numberProp(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    long n = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &n);
    else if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) n = CFBooleanGetValue(v);
    return n;
}

static void sample(const char *label) {
    uint8_t chie = 0xff;
    readCHIE(&chie);
    char source[32] = "?";
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info) {
        CFStringRef type = IOPSGetProvidingPowerSourceType(info);
        if (type) CFStringGetCString(type, source, sizeof source, kCFStringEncodingUTF8);
        CFRelease(info);
    }
    long external = -1, charging = -1, capacity = -1;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (svc) {
        CFMutableDictionaryRef props = NULL;  // fresh read each tick
        if (IORegistryEntryCreateCFProperties(svc, &props, NULL, 0) == KERN_SUCCESS && props) {
            external = numberProp(props, "ExternalConnected");
            charging = numberProp(props, "IsCharging");
            capacity = numberProp(props, "CurrentCapacity");
            CFRelease(props);
        }
        IOObjectRelease(svc);
    }
    printf("%-7s CHIE=0x%02x  DC-in=%6.2f W  battery=%6.2f W  current=%6d mA  source=%-13s plugged=%ld charging=%ld %ld%%\n",
           label, chie, readFloat("PDTR"), readFloat("PPBR"), readCurrent(), source, external, charging, capacity);
    fflush(stdout);
}

int main(void) {
    if (geteuid() != 0) { fprintf(stderr, "run with sudo (SMC writes need root)\n"); return 1; }

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
        fprintf(stderr, "cannot open AppleSMC\n");
        return 1;
    }
    IOObjectRelease(svc);

    uint8_t value;
    if (readCHIE(&value) != 0) { fprintf(stderr, "CHIE missing or not 1 byte; aborting\n"); return 1; }
    original = value;
    printf("CHIE originally 0x%02x\n", value);
    if (value != 0x00) { fprintf(stderr, "CHIE is not 0x00 to begin with; aborting to be safe\n"); return 1; }

    float dcIn = readFloat("PDTR");
    if (dcIn < 2.0f) {
        sample("before");
        fprintf(stderr, "\nAdapter is supplying %.2f W, so the Mac is already running from battery\n"
                        "(e.g. macOS draining down to its Charge Limit). The result would be masked.\n"
                        "Get it charging first (chargebar > Charge Once To 90%%), then rerun.\n", dcIn);
        return 4;
    }

    atexit(restore);
    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    signal(SIGHUP, onSignal);

    sample("before");
    restored = 0;
    if (writeCHIE(kAdapterOff) != 0) { restored = 1; return 2; }
    for (int i = 1; i <= 5; i++) {
        sleep(2);
        char label[16];
        snprintf(label, sizeof label, "t+%ds", i * 2);
        sample(label);
    }
    restore();
    sleep(3);
    sample("after");
    return restored ? 0 : 3;
}
