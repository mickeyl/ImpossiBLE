#import "CBSProxies.h"
#import "CBSConnection.h"
#import <objc/message.h>

#if TARGET_OS_SIMULATOR

// CBAttribute marks -init as NS_UNAVAILABLE, but it exists at runtime.
// Bypass the compile-time check via objc_msgSendSuper.
static id cbs_super_init(id self, Class superclass) {
    struct objc_super sup = { self, superclass };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(init));
}

static NSArray<NSString *> *cbs_uuid_strings(NSArray<CBUUID *> *uuids) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (CBUUID *uuid in uuids) {
        [out addObject:uuid.UUIDString ?: @""];
    }
    return out;
}

#pragma mark - CBSPeripheral

@implementation CBSPeripheral {
    NSUUID *_shimIdentifier;
    NSString *_shimName;
    CBPeripheralState _shimState;
}

- (instancetype)initWithIdentifier:(NSUUID *)identifier name:(NSString *)name {
    self = [super init];
    if (self) {
        _shimIdentifier = identifier;
        _shimName = [name copy];
        _shimState = CBPeripheralStateDisconnected;
    }
    return self;
}

- (NSUUID *)identifier { return _shimIdentifier; }
- (NSString *)name { return _shimName; }
- (CBPeripheralState)state { return _shimState; }

- (void)cbs_updateName:(NSString *)name {
    _shimName = [name copy];
}

- (void)cbs_setState:(CBPeripheralState)state {
    _shimState = state;
}

- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {
    NSArray<NSString *> *uuids = serviceUUIDs ? cbs_uuid_strings(serviceUUIDs) : @[];
    CBSConnectionSend(@{@"type": @"discoverServices", @"id": _shimIdentifier.UUIDString, @"services": uuids});
}

- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs forService:(CBService *)service {
    CBSService *svc = [service isKindOfClass:[CBSService class]] ? (CBSService *)service : nil;
    if (!svc || !svc.shimId) {
        return;
    }
    NSArray<NSString *> *uuids = characteristicUUIDs ? cbs_uuid_strings(characteristicUUIDs) : @[];
    CBSConnectionSend(@{
        @"type": @"discoverCharacteristics",
        @"id": _shimIdentifier.UUIDString,
        @"serviceId": svc.shimId,
        @"characteristics": uuids
    });
}

- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic {
    CBSCharacteristic *chr = [characteristic isKindOfClass:[CBSCharacteristic class]] ? (CBSCharacteristic *)characteristic : nil;
    if (!chr || !chr.shimId) {
        return;
    }
    CBSConnectionSend(@{@"type": @"read", @"id": _shimIdentifier.UUIDString, @"characteristicId": chr.shimId});
}

- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type {
    CBSCharacteristic *chr = [characteristic isKindOfClass:[CBSCharacteristic class]] ? (CBSCharacteristic *)characteristic : nil;
    if (!chr || !chr.shimId) {
        return;
    }
    NSString *b64 = data ? [data base64EncodedStringWithOptions:0] : @"";
    CBSConnectionSend(@{
        @"type": @"write",
        @"id": _shimIdentifier.UUIDString,
        @"characteristicId": chr.shimId,
        @"value": b64,
        @"writeType": @(type)
    });
}

- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic {
    CBSCharacteristic *chr = [characteristic isKindOfClass:[CBSCharacteristic class]] ? (CBSCharacteristic *)characteristic : nil;
    if (!chr || !chr.shimId) {
        return;
    }
    CBSConnectionSend(@{
        @"type": @"setNotify",
        @"id": _shimIdentifier.UUIDString,
        @"characteristicId": chr.shimId,
        @"enabled": @(enabled)
    });
}

- (void)openL2CAPChannel:(CBL2CAPPSM)PSM {
    CBSConnectionSend(@{@"type": @"openL2CAP", @"id": _shimIdentifier.UUIDString, @"psm": @(PSM)});
}

- (NSInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type {
    (void)type;
    return 512;
}

- (BOOL)canSendWriteWithoutResponse {
    return YES;
}

@end

#pragma mark - CBSService (subclass of CBService)

@implementation CBSService {
    CBUUID *_shimUUID;
    BOOL _shimPrimary;
    CBSPeripheral *_shimPeripheral;
    NSArray *_shimCharacteristics;
}

- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
                   primary:(BOOL)primary
                peripheral:(CBSPeripheral *)peripheral {
    self = cbs_super_init(self, [CBService class]);
    if (self) {
        _shimId = [shimId copy];
        _shimUUID = uuid;
        _shimPrimary = primary;
        _shimPeripheral = peripheral;
        _shimCharacteristics = @[];
    }
    return self;
}

- (CBUUID *)UUID { return _shimUUID; }
- (BOOL)isPrimary { return _shimPrimary; }
- (CBPeripheral *)peripheral { return (CBPeripheral *)_shimPeripheral; }
- (NSArray *)characteristics { return _shimCharacteristics; }
- (void)cbs_setCharacteristics:(NSArray *)characteristics { _shimCharacteristics = [characteristics copy]; }

@end

#pragma mark - CBSCharacteristic (subclass of CBCharacteristic)

@implementation CBSCharacteristic {
    CBUUID *_shimUUID;
    CBCharacteristicProperties _shimProperties;
    NSData *_shimValue;
    BOOL _shimNotifying;
    CBSService *_shimService;
}

- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
                properties:(CBCharacteristicProperties)properties
                   service:(CBSService *)service {
    self = cbs_super_init(self, [CBCharacteristic class]);
    if (self) {
        _shimId = [shimId copy];
        _shimUUID = uuid;
        _shimProperties = properties;
        _shimService = service;
        _shimValue = nil;
        _shimNotifying = NO;
    }
    return self;
}

- (CBUUID *)UUID { return _shimUUID; }
- (CBCharacteristicProperties)properties { return _shimProperties; }
- (CBService *)service { return (CBService *)_shimService; }

- (NSData *)value { return _shimValue; }
- (void)cbs_setValue:(NSData *)value { _shimValue = [value copy]; }

- (BOOL)isNotifying { return _shimNotifying; }
- (void)cbs_setNotifying:(BOOL)notifying { _shimNotifying = notifying; }

@end

#pragma mark - CBSChannel

@implementation CBSChannel {
    CBL2CAPPSM _shimPSM;
    NSInputStream *_shimInput;
    NSOutputStream *_shimOutput;
    CBPeer *_shimPeer;
}

- (instancetype)initWithId:(NSString *)shimId
                       psm:(CBL2CAPPSM)psm
               inputStream:(NSInputStream *)inputStream
              outputStream:(NSOutputStream *)outputStream
                      peer:(CBPeer *)peer {
    self = [super init];
    if (self) {
        _shimId = [shimId copy];
        _shimPSM = psm;
        _shimInput = inputStream;
        _shimOutput = outputStream;
        _shimPeer = peer;
    }
    return self;
}

- (CBL2CAPPSM)PSM { return _shimPSM; }
- (NSInputStream *)inputStream { return _shimInput; }
- (NSOutputStream *)outputStream { return _shimOutput; }
- (CBPeer *)peer { return _shimPeer; }

@end

#else

@implementation CBSPeripheral
- (instancetype)initWithIdentifier:(NSUUID *)identifier name:(NSString *)name { return nil; }
- (void)cbs_updateName:(NSString *)name {}
- (void)cbs_setState:(CBPeripheralState)state {}
- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {}
- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs forService:(CBService *)service {}
- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic {}
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type {}
- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic {}
- (void)openL2CAPChannel:(CBL2CAPPSM)PSM {}
- (NSInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type { return 0; }
- (BOOL)canSendWriteWithoutResponse { return NO; }
@end

@implementation CBSService
- (instancetype)initWithId:(NSString *)shimId uuid:(CBUUID *)uuid primary:(BOOL)primary peripheral:(CBSPeripheral *)peripheral { return nil; }
- (void)cbs_setCharacteristics:(NSArray *)characteristics {}
@end

@implementation CBSCharacteristic
- (instancetype)initWithId:(NSString *)shimId uuid:(CBUUID *)uuid properties:(CBCharacteristicProperties)properties service:(CBSService *)service { return nil; }
- (void)cbs_setValue:(NSData *)value {}
- (void)cbs_setNotifying:(BOOL)notifying {}
@end

@implementation CBSChannel
- (instancetype)initWithId:(NSString *)shimId psm:(CBL2CAPPSM)psm inputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream peer:(CBPeer *)peer { return nil; }
@end

#endif
