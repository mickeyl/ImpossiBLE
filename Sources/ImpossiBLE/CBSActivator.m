#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "CBSConnection.h"
#import "CBSProxies.h"

#if TARGET_OS_SIMULATOR

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>

static void *kCBSDelegateQueueKey = &kCBSDelegateQueueKey;

static CBCentralManager *gCentral;
static NSMutableDictionary<NSUUID *, CBSPeripheral *> *gPeripherals;
static NSMutableDictionary<NSString *, CBSService *> *gServices;
static NSMutableDictionary<NSString *, CBSCharacteristic *> *gCharacteristics;
static NSMutableDictionary<NSString *, CBSChannel *> *gL2CAPChannels;
static NSMutableDictionary<NSString *, dispatch_source_t> *gL2CAPReadSources;
static NSMutableDictionary<NSString *, NSNumber *> *gL2CAPFds;

#pragma mark - Helper Check

static void cbs_check_helper(void) {
    // The helper cannot be auto-launched from within the simulator process
    // because child processes inherit the simulator's Mach bootstrap namespace,
    // where XPC services (CoreBluetooth) are unavailable.
    // Start it from the host: make -C ~/Documents/late/ImpossiBLE watch
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"ImpossiBLE: WARNING — socket() failed, helper not reachable");
        return;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/impossible.sock", sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        close(fd);
        NSLog(@"ImpossiBLE: helper is running");
        return;
    }
    close(fd);
    NSLog(@"ImpossiBLE: WARNING — helper is NOT running. "
          "Start it from Terminal or add an Xcode pre-action: "
          "open -a \"$HOME/.local/bin/impossible-helper.app\"");
}

#pragma mark - Callback Dispatch

static dispatch_queue_t cbs_callback_queue(void) {
    CBCentralManager *central = gCentral;
    dispatch_queue_t queue = objc_getAssociatedObject(central, kCBSDelegateQueueKey);
    return queue ?: dispatch_get_main_queue();
}

static NSError *cbs_error_from_message(NSString *errStr) {
    if (![errStr isKindOfClass:[NSString class]] || errStr.length == 0) {
        return nil;
    }
    return [NSError errorWithDomain:@"ImpossiBLE" code:1 userInfo:@{NSLocalizedDescriptionKey: errStr}];
}

#pragma mark - L2CAP Helpers

static void cbs_l2cap_close(NSString *chanId) {
    if (![chanId isKindOfClass:[NSString class]]) {
        return;
    }
    CBSChannel *channel = gL2CAPChannels[chanId];
    if (channel) {
        [channel.inputStream close];
        [channel.outputStream close];
    }
    dispatch_source_t src = gL2CAPReadSources[chanId];
    if (src) {
        dispatch_source_cancel(src);
        [gL2CAPReadSources removeObjectForKey:chanId];
    }
    NSNumber *fdNum = gL2CAPFds[chanId];
    if (fdNum) {
        close(fdNum.intValue);
        [gL2CAPFds removeObjectForKey:chanId];
    }
    [gL2CAPChannels removeObjectForKey:chanId];
}

static void cbs_l2cap_setup_read(NSString *chanId, int fd) {
    if (!gL2CAPReadSources) {
        gL2CAPReadSources = [NSMutableDictionary dictionary];
    }
    if (!gL2CAPFds) {
        gL2CAPFds = [NSMutableDictionary dictionary];
    }
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!src) {
        return;
    }
    dispatch_source_set_event_handler(src, ^{
        uint8_t buf[2048];
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            CBSConnectionSend(@{@"type": @"l2capClose", @"channelId": chanId});
            cbs_l2cap_close(chanId);
            return;
        }
        NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
        NSString *b64 = [data base64EncodedStringWithOptions:0];
        CBSConnectionSend(@{@"type": @"l2capWrite", @"channelId": chanId, @"value": b64});
    });
    dispatch_source_set_cancel_handler(src, ^{
        close(fd);
    });
    dispatch_resume(src);
    gL2CAPReadSources[chanId] = src;
    gL2CAPFds[chanId] = @(fd);
}

#pragma mark - Message Handler

static void cbs_handle_message(NSDictionary *msg) {
    NSString *type = msg[@"type"];
    if (![type isKindOfClass:[NSString class]]) {
        return;
    }

    if ([type isEqualToString:@"didDiscover"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *name = msg[@"name"] ?: @"";
        NSNumber *rssi = msg[@"rssi"] ?: @0;
        NSDictionary *adv = msg[@"adv"];
        if (![adv isKindOfClass:[NSDictionary class]]) {
            adv = @{};
        }
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        if (!gPeripherals) {
            gPeripherals = [NSMutableDictionary dictionary];
        }
        CBSPeripheral *peripheral = gPeripherals[uuid];
        if (!peripheral) {
            peripheral = [[CBSPeripheral alloc] initWithIdentifier:uuid name:name];
            gPeripherals[uuid] = peripheral;
        } else {
            [peripheral cbs_updateName:name];
        }

        CBCentralManager *central = gCentral;
        id<CBCentralManagerDelegate> delegate = central.delegate;
        if (!central || !delegate) {
            return;
        }
        if (![delegate respondsToSelector:@selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        CBPeripheral *cbPeripheral = (CBPeripheral *)peripheral;
        dispatch_async(queue, ^{
            [delegate centralManager:central
               didDiscoverPeripheral:cbPeripheral
                    advertisementData:adv
                                 RSSI:rssi];
        });
        return;
    }

    if ([type isEqualToString:@"didConnect"] || [type isEqualToString:@"didFailConnect"] || [type isEqualToString:@"didDisconnect"]) {
        NSString *uuidStr = msg[@"id"];
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        CBSPeripheral *peripheral = gPeripherals[uuid];
        if (!peripheral) {
            return;
        }
        if ([type isEqualToString:@"didConnect"]) {
            [peripheral cbs_setState:CBPeripheralStateConnected];
        } else {
            [peripheral cbs_setState:CBPeripheralStateDisconnected];
        }

        CBCentralManager *central = gCentral;
        id<CBCentralManagerDelegate> delegate = central.delegate;
        if (!central || !delegate) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        CBPeripheral *cbPeripheral = (CBPeripheral *)peripheral;
        NSError *err = cbs_error_from_message(msg[@"error"]);
        dispatch_async(queue, ^{
            if ([type isEqualToString:@"didConnect"] &&
                [delegate respondsToSelector:@selector(centralManager:didConnectPeripheral:)]) {
                [delegate centralManager:central didConnectPeripheral:cbPeripheral];
            } else if ([type isEqualToString:@"didFailConnect"] &&
                       [delegate respondsToSelector:@selector(centralManager:didFailToConnectPeripheral:error:)]) {
                [delegate centralManager:central didFailToConnectPeripheral:cbPeripheral error:err];
            } else if ([type isEqualToString:@"didDisconnect"] &&
                       [delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:error:)]) {
                [delegate centralManager:central didDisconnectPeripheral:cbPeripheral error:err];
            }
        });
        return;
    }

    if ([type isEqualToString:@"didDiscoverServices"]) {
        NSString *uuidStr = msg[@"id"];
        NSArray *services = msg[@"services"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![services isKindOfClass:[NSArray class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = uuid ? gPeripherals[uuid] : nil;
        if (!peripheral) {
            return;
        }
        if (!gServices) {
            gServices = [NSMutableDictionary dictionary];
        }
        NSMutableArray *svcList = [NSMutableArray array];
        for (NSDictionary *svc in services) {
            if (![svc isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *svcId = svc[@"id"];
            NSString *svcUuid = svc[@"uuid"];
            NSNumber *primary = svc[@"primary"] ?: @0;
            if (![svcId isKindOfClass:[NSString class]] || ![svcUuid isKindOfClass:[NSString class]]) {
                continue;
            }
            CBUUID *uuidObj = [CBUUID UUIDWithString:svcUuid];
            CBSService *service = [[CBSService alloc] initWithId:svcId uuid:uuidObj primary:primary.boolValue peripheral:peripheral];
            gServices[svcId] = service;
            [svcList addObject:service];
        }
        peripheral.services = svcList;
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didDiscoverServices:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didDiscoverServices:err];
        });
        return;
    }

    if ([type isEqualToString:@"didDiscoverCharacteristics"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *serviceId = msg[@"serviceId"];
        NSArray *chars = msg[@"characteristics"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![serviceId isKindOfClass:[NSString class]] || ![chars isKindOfClass:[NSArray class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = uuid ? gPeripherals[uuid] : nil;
        CBSService *service = gServices[serviceId];
        if (!peripheral || !service) {
            return;
        }
        if (!gCharacteristics) {
            gCharacteristics = [NSMutableDictionary dictionary];
        }
        NSMutableArray *chrList = [NSMutableArray array];
        for (NSDictionary *ch in chars) {
            if (![ch isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *chId = ch[@"id"];
            NSString *chUuid = ch[@"uuid"];
            NSNumber *props = ch[@"properties"] ?: @0;
            if (![chId isKindOfClass:[NSString class]] || ![chUuid isKindOfClass:[NSString class]]) {
                continue;
            }
            CBUUID *uuidObj = [CBUUID UUIDWithString:chUuid];
            CBSCharacteristic *chr = [[CBSCharacteristic alloc] initWithId:chId uuid:uuidObj properties:props.unsignedIntegerValue service:service];
            gCharacteristics[chId] = chr;
            [chrList addObject:chr];
        }
        [service cbs_setCharacteristics:chrList];
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didDiscoverCharacteristicsForService:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didUpdateValue"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *chId = msg[@"characteristicId"];
        NSString *valueB64 = msg[@"value"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![chId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = uuid ? gPeripherals[uuid] : nil;
        CBSCharacteristic *chr = gCharacteristics[chId];
        if (!peripheral || !chr) {
            return;
        }
        if ([valueB64 isKindOfClass:[NSString class]] && valueB64.length > 0) {
            [chr cbs_setValue:[[NSData alloc] initWithBase64EncodedString:valueB64 options:0]];
        } else {
            [chr cbs_setValue:nil];
        }
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didUpdateValueForCharacteristic:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)chr error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didWriteValue"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *chId = msg[@"characteristicId"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![chId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = uuid ? gPeripherals[uuid] : nil;
        CBSCharacteristic *chr = gCharacteristics[chId];
        if (!peripheral || !chr) {
            return;
        }
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didWriteValueForCharacteristic:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)chr error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didUpdateNotification"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *chId = msg[@"characteristicId"];
        NSNumber *enabled = msg[@"enabled"] ?: @0;
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![chId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = uuid ? gPeripherals[uuid] : nil;
        CBSCharacteristic *chr = gCharacteristics[chId];
        if (!peripheral || !chr) {
            return;
        }
        [chr cbs_setNotifying:enabled.boolValue];
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didUpdateNotificationStateForCharacteristic:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue();
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)chr error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didOpenL2CAP"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *chanId = msg[@"channelId"];
        NSNumber *psmNum = msg[@"psm"] ?: @0;
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![chanId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = uuid ? gPeripherals[uuid] : nil;
        if (!peripheral) {
            return;
        }
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didOpenL2CAPChannel:error:)]) {
            return;
        }
        CBSChannel *channel = nil;
        if (!err) {
            int fds[2] = {-1, -1};
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0) {
                CFReadStreamRef readStream = NULL;
                CFWriteStreamRef writeStream = NULL;
                CFStreamCreatePairWithSocket(kCFAllocatorDefault, fds[0], &readStream, &writeStream);
                NSInputStream *inStream = readStream ? (__bridge_transfer NSInputStream *)readStream : nil;
                NSOutputStream *outStream = writeStream ? (__bridge_transfer NSOutputStream *)writeStream : nil;
                if (inStream && outStream) {
                    [inStream open];
                    [outStream open];
                    channel = [[CBSChannel alloc] initWithId:chanId
                                                         psm:(CBL2CAPPSM)psmNum.unsignedShortValue
                                                 inputStream:inStream
                                                outputStream:outStream
                                                        peer:(CBPeer *)peripheral];
                    if (!gL2CAPChannels) {
                        gL2CAPChannels = [NSMutableDictionary dictionary];
                    }
                    gL2CAPChannels[chanId] = channel;
                    cbs_l2cap_setup_read(chanId, fds[1]);
                } else {
                    if (fds[0] >= 0) close(fds[0]);
                    if (fds[1] >= 0) close(fds[1]);
                    err = [NSError errorWithDomain:@"ImpossiBLE" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create L2CAP streams"}];
                }
            } else {
                err = [NSError errorWithDomain:@"ImpossiBLE" code:2 userInfo:@{NSLocalizedDescriptionKey: @"socketpair failed"}];
            }
        }
        dispatch_queue_t queue = cbs_callback_queue();
        CBL2CAPChannel *cbChannel = (CBL2CAPChannel *)channel;
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didOpenL2CAPChannel:cbChannel error:err];
        });
        return;
    }

    if ([type isEqualToString:@"l2capData"]) {
        NSString *chanId = msg[@"channelId"];
        NSString *b64 = msg[@"value"];
        if (![chanId isKindOfClass:[NSString class]] || ![b64 isKindOfClass:[NSString class]]) {
            return;
        }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        NSNumber *fdNum = gL2CAPFds[chanId];
        if (!data || !fdNum) {
            return;
        }
        write(fdNum.intValue, data.bytes, data.length);
        return;
    }

    if ([type isEqualToString:@"l2capClosed"]) {
        NSString *chanId = msg[@"channelId"];
        if (![chanId isKindOfClass:[NSString class]]) {
            return;
        }
        cbs_l2cap_close(chanId);
        return;
    }
}

#pragma mark - Swizzled Implementations

static NSArray<NSString *> *cbs_uuid_strings(NSArray<CBUUID *> *uuids) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (CBUUID *uuid in uuids) {
        [out addObject:uuid.UUIDString ?: @""];
    }
    return out;
}

static void cbs_post_init(id obj, id delegate, dispatch_queue_t queue) {
    dispatch_queue_t q = queue ?: dispatch_get_main_queue();
    objc_setAssociatedObject(obj, kCBSDelegateQueueKey, q, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gCentral = obj;
    if (delegate && [delegate respondsToSelector:@selector(centralManagerDidUpdateState:)]) {
        dispatch_async(q, ^{
            [delegate centralManagerDidUpdateState:obj];
        });
    }
}

static id (*orig_init)(id, SEL, id, dispatch_queue_t, NSDictionary *);
static id cbs_init(id self, SEL _cmd, id delegate, dispatch_queue_t queue, NSDictionary *options) {
    id obj = orig_init(self, _cmd, delegate, queue, options);
    cbs_post_init(obj, delegate, queue);
    return obj;
}

static id (*orig_init_noopts)(id, SEL, id, dispatch_queue_t);
static id cbs_init_noopts(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    id obj = orig_init_noopts(self, _cmd, delegate, queue);
    cbs_post_init(obj, delegate, queue);
    return obj;
}

static CBManagerState (*orig_state)(id, SEL);
static CBManagerState cbs_state(id self, SEL _cmd) {
    return CBManagerStatePoweredOn;
}

static CBManagerAuthorization (*orig_authorization)(id, SEL);
static CBManagerAuthorization cbs_authorization(id self, SEL _cmd) {
    return CBManagerAuthorizationAllowedAlways;
}

static CBManagerAuthorization (*orig_class_authorization)(id, SEL);
static CBManagerAuthorization cbs_class_authorization(id self, SEL _cmd) {
    return CBManagerAuthorizationAllowedAlways;
}

static BOOL (*orig_supports_features)(id, SEL, CBCentralManagerFeature);
static BOOL cbs_supports_features(id self, SEL _cmd, CBCentralManagerFeature features) {
    return YES;
}

static void (*orig_setDelegate)(id, SEL, id);
static void cbs_setDelegate(id self, SEL _cmd, id delegate) {
    orig_setDelegate(self, _cmd, delegate);
    gCentral = self;
    dispatch_queue_t q = objc_getAssociatedObject(self, kCBSDelegateQueueKey);
    if (!q) {
        q = dispatch_get_main_queue();
    }
    if (delegate && [delegate respondsToSelector:@selector(centralManagerDidUpdateState:)]) {
        dispatch_async(q, ^{
            [delegate centralManagerDidUpdateState:self];
        });
    }
}

static void (*orig_scan)(id, SEL, NSArray *, NSDictionary *);
static void cbs_scan(id self, SEL _cmd, NSArray *services, NSDictionary *options) {
    gCentral = self;
    NSArray<NSString *> *uuids = services ? cbs_uuid_strings(services) : @[];
    CBSConnectionSend(@{@"type": @"scan", @"services": uuids, @"options": options ?: @{}});

    // Re-deliver already-known peripherals to the current delegate.
    // CoreBluetooth won't re-report peripherals that were already discovered
    // in a previous scan, so a second CBCentralManager would never see them.
    if (gPeripherals.count > 0) {
        id<CBCentralManagerDelegate> delegate = [(CBCentralManager *)self delegate];
        if (delegate && [delegate respondsToSelector:@selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:)]) {
            dispatch_queue_t queue = cbs_callback_queue();
            for (NSUUID *uuid in gPeripherals) {
                CBSPeripheral *peripheral = gPeripherals[uuid];
                CBPeripheral *cbPeripheral = (CBPeripheral *)peripheral;
                dispatch_async(queue, ^{
                    [delegate centralManager:self
                       didDiscoverPeripheral:cbPeripheral
                            advertisementData:@{}
                                         RSSI:@0];
                });
            }
        }
    }
}

static void (*orig_stop)(id, SEL);
static void cbs_stop(id self, SEL _cmd) {
    gCentral = self;
    CBSConnectionSend(@{@"type": @"stopScan"});
}

static void (*orig_connect)(id, SEL, id, NSDictionary *);
static void cbs_connect_peripheral(id self, SEL _cmd, id peripheral, NSDictionary *options) {
    gCentral = self;
    id ident = [peripheral respondsToSelector:@selector(identifier)] ? [peripheral identifier] : nil;
    NSUUID *uuid = [ident isKindOfClass:[NSUUID class]] ? ident : nil;
    if (uuid) {
        CBSConnectionSend(@{@"type": @"connect", @"id": uuid.UUIDString, @"options": options ?: @{}});
    }
}

static void (*orig_cancel)(id, SEL, id);
static void cbs_cancel(id self, SEL _cmd, id peripheral) {
    gCentral = self;
    id ident = [peripheral respondsToSelector:@selector(identifier)] ? [peripheral identifier] : nil;
    NSUUID *uuid = [ident isKindOfClass:[NSUUID class]] ? ident : nil;
    if (uuid) {
        CBSConnectionSend(@{@"type": @"cancel", @"id": uuid.UUIDString});
    }
}

#pragma mark - Swizzle Infrastructure

static void cbs_swizzle(Class cls, SEL sel, IMP imp, IMP *orig_out) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    if (orig_out) {
        *orig_out = orig;
    }
}

static void cbs_swizzle_class(Class cls, SEL sel, IMP imp, IMP *orig_out) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    if (orig_out) {
        *orig_out = orig;
    }
}

#pragma mark - +load Entry Point

@interface CBSActivator : NSObject
@end

@implementation CBSActivator

+ (void)load {
    NSLog(@"ImpossiBLE: loaded");

    Class cls = NSClassFromString(@"CBCentralManager");
    if (!cls) {
        NSLog(@"ImpossiBLE: CBCentralManager not found");
        return;
    }

    CBSConnectionSetMessageHandler(^(NSDictionary *msg) {
        cbs_handle_message(msg);
    });

    cbs_check_helper();

    cbs_swizzle(cls, @selector(initWithDelegate:queue:options:), (IMP)cbs_init, (IMP *)&orig_init);
    cbs_swizzle(cls, @selector(initWithDelegate:queue:), (IMP)cbs_init_noopts, (IMP *)&orig_init_noopts);
    cbs_swizzle(cls, @selector(state), (IMP)cbs_state, (IMP *)&orig_state);
    cbs_swizzle(cls, @selector(authorization), (IMP)cbs_authorization, (IMP *)&orig_authorization);
    cbs_swizzle_class(cls, @selector(authorization), (IMP)cbs_class_authorization, (IMP *)&orig_class_authorization);
    cbs_swizzle_class(cls, @selector(supportsFeatures:), (IMP)cbs_supports_features, (IMP *)&orig_supports_features);
    cbs_swizzle(cls, @selector(setDelegate:), (IMP)cbs_setDelegate, (IMP *)&orig_setDelegate);
    cbs_swizzle(cls, @selector(scanForPeripheralsWithServices:options:), (IMP)cbs_scan, (IMP *)&orig_scan);
    cbs_swizzle(cls, @selector(stopScan), (IMP)cbs_stop, (IMP *)&orig_stop);
    cbs_swizzle(cls, @selector(connectPeripheral:options:), (IMP)cbs_connect_peripheral, (IMP *)&orig_connect);
    cbs_swizzle(cls, @selector(cancelPeripheralConnection:), (IMP)cbs_cancel, (IMP *)&orig_cancel);

    Class mgr = NSClassFromString(@"CBManager");
    if (mgr) {
        cbs_swizzle(mgr, @selector(authorization), (IMP)cbs_authorization, NULL);
        cbs_swizzle_class(mgr, @selector(authorization), (IMP)cbs_class_authorization, NULL);
    }

    NSLog(@"ImpossiBLE: swizzles installed");
}

@end

#endif
