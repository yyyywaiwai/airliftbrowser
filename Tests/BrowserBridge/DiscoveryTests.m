#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <assert.h>

SInt32 TestRunLoop(CFRunLoopMode mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled);

// Substitute only discovery's device API; the production callback runs unchanged.
#define AMDeviceGetInterfaceType TestInterface
#define AMDeviceConnect TestConnect
#define AMDeviceDisconnect TestDisconnect
#define AMDeviceIsPaired TestPaired
#define AMDeviceValidatePairing TestValidate
#define AMDeviceStartSession TestStartSession
#define AMDeviceStopSession TestStopSession
#define AMDeviceCopyDeviceIdentifier TestIdentifier
#define AMDeviceCopyValue TestValue
#define AMDeviceNotificationSubscribeWithOptions TestSubscribe
#define AMDeviceNotificationUnsubscribe TestUnsubscribe
#define CFRunLoopRunInMode TestRunLoop
#include "../../Sources/BrowserBridge/main.m"

static NSDictionary *Fixture(AMDeviceRef device) { return (__bridge NSDictionary *)device; }
static int Connected, Sessions;
static int SubscribeStatus;
static NSDictionary *Options;
int TestInterface(AMDeviceRef device) { return [Fixture(device)[@"interface"] intValue]; }
int TestConnect(AMDeviceRef device) { (void)device; Connected++; return 0; }
int TestDisconnect(AMDeviceRef device) { (void)device; Connected--; return 0; }
int TestPaired(AMDeviceRef device) { return [Fixture(device)[@"paired"] boolValue]; }
int TestValidate(AMDeviceRef device) { return [Fixture(device)[@"validate"] intValue]; }
int TestStartSession(AMDeviceRef device) {
    if ([Fixture(device)[@"locked"] boolValue]) return 1;
    Sessions++;
    return 0;
}
int TestStopSession(AMDeviceRef device) { (void)device; Sessions--; return 0; }
CFStringRef TestIdentifier(AMDeviceRef device) {
    return CFBridgingRetain(Fixture(device)[@"id"]);
}
CFTypeRef TestValue(AMDeviceRef device, CFStringRef domain, CFStringRef key) {
    (void)domain;
    assert(Sessions == 1); // Wi-Fi metadata must be read inside a paired session.
    NSDictionary *values = @{ @"DeviceName": @"Test device", @"ProductVersion": @"27.0",
                              @"ProductType": Fixture(device)[@"product"] ?: @"iPhone15,4" };
    return CFBridgingRetain(values[(__bridge NSString *)key]);
}
int TestSubscribe(void (*callback)(AMDeviceNotificationCallbackInfo *, void *),
                  int unused, unsigned int type, void *context,
                  AMDeviceNotificationRef *subscription, CFDictionaryRef options) {
    (void)callback; (void)unused; (void)type; (void)context;
    Options = (__bridge NSDictionary *)options;
    *subscription = NULL;
    return SubscribeStatus;
}
int TestUnsubscribe(AMDeviceNotificationRef subscription) { (void)subscription; return 0; }
SInt32 TestRunLoop(CFRunLoopMode mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled) {
    (void)mode;
    assert(seconds >= 10 && !returnAfterSourceHandled);
    return kCFRunLoopRunFinished;
}

static void Notify(NSDictionary *device) {
    AMDeviceNotificationCallbackInfo info = { (__bridge AMDeviceRef)device, 1 };
    Discover(&info, NULL);
    assert(Connected == 0 && Sessions == 0);
}

__attribute__((constructor)) static void RunDiscoveryTests(void) {
    @autoreleasepool {
        assert([DiscoverDevices()[@"ok"] boolValue]);
        assert([Options[@"NotificationOptionSearchForPairedDevices"] boolValue]);
        assert(![Options[@"NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly"] boolValue]);
        assert(![Options[@"NotificationOptionSearchForWiFiPairableDevices"] boolValue]);
        assert([Options[@"NotificationOptionEnableUSBMux"] boolValue]);
        assert([Options[@"NotificationOptionEnableRemoteXPC"] boolValue]);
        Discover(NULL, NULL);
        AMDeviceNotificationCallbackInfo missing = { NULL, 1 };
        Discover(&missing, NULL);
        NSDictionary *wifi = @{ @"id": @"phone", @"interface": @2, @"paired": @YES };
        NSDictionary *usb = @{ @"id": @"phone", @"interface": @1, @"paired": @YES };
        Notify(wifi);
        assert([Devices[@"phone"][@"transport"] isEqual:@"Wi-Fi"]);
        Notify(usb);
        Notify(wifi);
        assert(Devices.count == 1 && [Devices[@"phone"][@"transport"] isEqual:@"USB"]);
        [Devices removeAllObjects];
        Notify(usb);
        Notify(wifi);
        assert(Devices.count == 1 && [Devices[@"phone"][@"transport"] isEqual:@"USB"]);
        Notify(@{ @"id": @"ipad", @"interface": @2, @"paired": @YES, @"product": @"iPad14,8" });
        assert([Devices[@"ipad"][@"transport"] isEqual:@"Wi-Fi"]);
        Notify(@{ @"id": @"unknown", @"interface": @0, @"paired": @YES });
        Notify(@{ @"id": @"unpaired", @"interface": @2, @"paired": @NO });
        Notify(@{ @"id": @"invalid", @"interface": @2, @"paired": @YES, @"validate": @1 });
        Notify(@{ @"id": @"locked", @"interface": @2, @"paired": @YES, @"locked": @YES });
        Notify(@{ @"id": @"watch", @"interface": @2, @"paired": @YES, @"product": @"Watch1,1" });
        assert(Devices.count == 2);
        AMDeviceNotificationCallbackInfo removed = { (__bridge AMDeviceRef)wifi, 2 };
        Discover(&removed, NULL);
        assert(Devices.count == 2);
        SubscribeStatus = 1;
        assert(![DiscoverDevices()[@"ok"] boolValue]);
        puts("Discovery tests passed (Wi-Fi, USB preference, pairing, sessions, errors).");
        exit(0);
    }
}
