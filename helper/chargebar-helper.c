// chargebar-helper: root LaunchDaemon that enforces caps below 80% and sailing by
// switching the charger with SMC key CHIE (0x08 = adapter off, 0x00 = on).
//
// The app sends a policy over XPC ({op: "policy", enabled, cap, floor}) at launch
// and every 60 s as a heartbeat. The helper then:
//   - cuts the charger (CHIE=0x08) when charge >= cap,
//   - reconnects it (CHIE=0x00) when charge <= floor,
//   - otherwise leaves the current state (that's the sailing band).
//
// Fail-safe: the charger is reconnected (CHIE=0x00) at startup, on exit and on
// SIGTERM/SIGINT/SIGHUP, before system sleep (unless the policy allows sailing
// through sleep and charge is well above the floor), when the policy is disabled or
// invalid (floor < 20 or floor >= cap), and when the app hasn't sent a heartbeat for
// 5 minutes. launchd (KeepAlive) restarts the helper after a crash, and startup
// reconnects first. macOS's own 80% Charge Limit stays on as the backstop.
//
// Build: see scripts/build.sh. Install: scripts/install-helper.sh (needs sudo).

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SERVICE_NAME "net.digital-shokunin.chargebar.helper"
#define CLIENT_REQUIREMENT "identifier \"net.digital-shokunin.chargebar\""
#define HEARTBEAT_TIMEOUT_S 300
#define EVALUATE_INTERVAL_S 30
#define MIN_FLOOR 20
#define MAX_CAP 100
#define SLEEP_SAIL_MARGIN 5  // keep the cut through sleep only above floor + this

static os_log_t logger;

// MARK: - SMC

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
enum { kChargerOn = 0x00, kChargerOff = 0x08 };

static io_connect_t smc;

static int smcCall(SMCKeyData *in, SMCKeyData *out) {
    size_t size = sizeof(*out);
    kern_return_t kr = IOConnectCallStructMethod(smc, kSMCHandleYPCEvent, in, sizeof(*in), out, &size);
    return (kr == kIOReturnSuccess && out->result == 0) ? 0 : -1;
}

static int readCHIE(uint8_t *value) {
    SMCKeyData in = {0}, out = {0};
    in.key = kCHIE;
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(&in, &out) != 0 || out.keyInfo.dataSize != 1) return -1;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = kCHIE;
    in.keyInfo.dataSize = 1;
    in.data8 = kSMCReadKey;
    if (smcCall(&in, &out) != 0) return -1;
    *value = out.bytes[0];
    return 0;
}

static int writeCHIE(uint8_t value) {
    SMCKeyData in = {0}, out = {0};
    in.key = kCHIE;
    in.keyInfo.dataSize = 1;
    in.data8 = kSMCWriteKey;
    in.bytes[0] = value;
    if (smcCall(&in, &out) != 0) {
        os_log_error(logger, "write CHIE=0x%02x failed", value);
        return -1;
    }
    uint8_t check = 0xff;
    if (readCHIE(&check) != 0 || check != value) {
        os_log_error(logger, "CHIE read-back 0x%02x after writing 0x%02x", check, value);
        return -1;
    }
    return 0;
}

/// Async-signal-safe enough for our use: plain IOKit call, no allocation.
static void reconnect(const char *why) {
    uint8_t v = 0xff;
    if (readCHIE(&v) == 0 && v == kChargerOn) return;
    if (writeCHIE(kChargerOn) == 0) os_log(logger, "charger reconnected (%{public}s)", why);
}

// MARK: - Battery

static int chargePercent(void) {
    int percent = -1;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        if (!d) continue;
        CFStringRef type = CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
        if (!type || CFStringCompare(type, CFSTR(kIOPSInternalBatteryType), 0) != kCFCompareEqualTo) continue;
        int cur = 0, max = 0;
        CFNumberRef n;
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey)))) CFNumberGetValue(n, kCFNumberIntType, &cur);
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey)))) CFNumberGetValue(n, kCFNumberIntType, &max);
        percent = max > 0 ? (cur * 100 + max / 2) / max : cur;
        break;
    }
    if (list) CFRelease(list);
    CFRelease(info);
    return percent;
}

// MARK: - Policy and control loop (all on the main queue)

static struct {
    int enabled;
    int cap;
    int floor;
    int sailDuringSleep;
    time_t lastHeartbeat;
} policy;

static time_t sleptAt;  // 0 when awake

static const char *lastAction = "starting";
static int sleeping;

static void evaluate(void) {
    if (sleeping) return;
    uint8_t chie = 0xff;
    if (readCHIE(&chie) != 0) { lastAction = "CHIE unreadable"; return; }

    if (!policy.enabled) { reconnect("policy off"); lastAction = "idle"; return; }
    if (time(NULL) - policy.lastHeartbeat > HEARTBEAT_TIMEOUT_S) {
        reconnect("no heartbeat from chargebar");
        lastAction = "idle (app not responding)";
        return;
    }

    int percent = chargePercent();
    if (percent < 0) { reconnect("battery unreadable"); lastAction = "battery unreadable"; return; }

    if (percent <= policy.floor || percent <= MIN_FLOOR) {
        if (chie != kChargerOn) {
            writeCHIE(kChargerOn);
            os_log(logger, "at %d%% (floor %d%%): charger on", percent, policy.floor);
        }
        lastAction = "charging";
    } else if (percent >= policy.cap) {
        if (chie != kChargerOff) {
            writeCHIE(kChargerOff);
            os_log(logger, "at %d%% (cap %d%%): charger cut", percent, policy.cap);
        }
        lastAction = "cutting";
    } else {
        lastAction = chie == kChargerOff ? "cutting" : "charging";
    }
}

static xpc_object_t statusReply(xpc_object_t request, const char *error) {
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!reply) return NULL;
    uint8_t chie = 0xff;
    readCHIE(&chie);
    xpc_dictionary_set_bool(reply, "ok", error == NULL);
    if (error) xpc_dictionary_set_string(reply, "error", error);
    xpc_dictionary_set_string(reply, "state", lastAction);
    xpc_dictionary_set_int64(reply, "chie", chie);
    xpc_dictionary_set_int64(reply, "percent", chargePercent());
    xpc_dictionary_set_bool(reply, "enabled", policy.enabled);
    xpc_dictionary_set_int64(reply, "cap", policy.cap);
    xpc_dictionary_set_int64(reply, "floor", policy.floor);
    xpc_dictionary_set_bool(reply, "sailDuringSleep", policy.sailDuringSleep);
    return reply;
}

static void handleMessage(xpc_connection_t peer, xpc_object_t message) {
    const char *op = xpc_dictionary_get_string(message, "op");
    const char *error = NULL;
    if (op && strcmp(op, "policy") == 0) {
        int enabled = xpc_dictionary_get_bool(message, "enabled");
        int cap = (int)xpc_dictionary_get_int64(message, "cap");
        int floor = (int)xpc_dictionary_get_int64(message, "floor");
        int sailDuringSleep = xpc_dictionary_get_bool(message, "sailDuringSleep");
        if (enabled && (cap > MAX_CAP || floor < MIN_FLOOR || floor >= cap)) {
            error = "invalid policy (need 20 <= floor < cap <= 100)";
            policy.enabled = 0;
        } else {
            if (enabled != policy.enabled || cap != policy.cap || floor != policy.floor) {
                os_log(logger, "policy: %{public}s cap=%d floor=%d", enabled ? "on" : "off", cap, floor);
            }
            policy.enabled = enabled;
            policy.cap = cap;
            policy.floor = floor;
            policy.sailDuringSleep = sailDuringSleep;
        }
        policy.lastHeartbeat = time(NULL);
        evaluate();
    } else if (!op || strcmp(op, "status") != 0) {
        error = "unknown op";
    }
    xpc_object_t reply = statusReply(message, error);
    if (reply) {
        xpc_connection_send_message(peer, reply);
        xpc_release(reply);
    }
}

// MARK: - Sleep / wake

static io_connect_t rootPort;

static void powerCallback(void *refcon, io_service_t service, natural_t type, void *arg) {
    (void)refcon; (void)service;
    switch (type) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(rootPort, (long)arg);
        break;
    case kIOMessageSystemWillSleep: {
        int percent = chargePercent();
        int keepCut = policy.enabled && policy.sailDuringSleep && percent >= 0 &&
                      percent > policy.floor + SLEEP_SAIL_MARGIN && percent > MIN_FLOOR + SLEEP_SAIL_MARGIN;
        if (keepCut) {
            os_log(logger, "sleeping at %d%%: leaving charger state as is (sail during sleep)", percent);
        } else {
            reconnect("system sleep");
        }
        sleeping = 1;
        sleptAt = time(NULL);
        IOAllowPowerChange(rootPort, (long)arg);
        break;
    }
    case kIOMessageSystemHasPoweredOn:
        // Fires on full and dark wakes. The app can't send heartbeats while asleep,
        // so don't count time asleep against the heartbeat timeout.
        if (sleptAt) policy.lastHeartbeat += time(NULL) - sleptAt;
        sleptAt = 0;
        sleeping = 0;
        evaluate();
        break;
    }
}

static void powerSourceChanged(void *context) {
    (void)context;
    evaluate();
}

// MARK: - Shutdown

static void reconnectAtExit(void) { reconnect("exit"); }

static void onSignal(int sig) {
    reconnect("signal");
    _exit(128 + sig);
}

int main(void) {
    logger = os_log_create(SERVICE_NAME, "helper");

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &smc) != kIOReturnSuccess) {
        os_log_error(logger, "cannot open AppleSMC");
        return 1;
    }
    IOObjectRelease(svc);
    uint8_t chie;
    if (readCHIE(&chie) != 0) {
        os_log_error(logger, "CHIE not available on this Mac; exiting");
        return 1;
    }

    // Always start from a safe state, e.g. after a crash with the charger cut.
    reconnect("startup");
    atexit(reconnectAtExit);
    signal(SIGTERM, onSignal);
    signal(SIGINT, onSignal);
    signal(SIGHUP, onSignal);

    IONotificationPortRef notifyPort;
    io_object_t notifier;
    rootPort = IORegisterForSystemPower(NULL, &notifyPort, powerCallback, &notifier);
    if (rootPort) IONotificationPortSetDispatchQueue(notifyPort, dispatch_get_main_queue());

    CFRunLoopSourceRef psSource = IOPSNotificationCreateRunLoopSource(powerSourceChanged, NULL);
    if (psSource) CFRunLoopAddSource(CFRunLoopGetMain(), psSource, kCFRunLoopDefaultMode);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, EVALUATE_INTERVAL_S * NSEC_PER_SEC),
                              EVALUATE_INTERVAL_S * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ evaluate(); });
    dispatch_resume(timer);

    xpc_connection_t listener = xpc_connection_create_mach_service(SERVICE_NAME, dispatch_get_main_queue(),
                                                                   XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        // Only chargebar may talk to the helper.
        if (xpc_connection_set_peer_code_signing_requirement(peer, CLIENT_REQUIREMENT) != 0) {
            xpc_connection_cancel(peer);
            return;
        }
        xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) handleMessage(peer, event);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);

    os_log(logger, "chargebar-helper started");
    CFRunLoopRun();
    return 0;
}
