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
    id<CBPeripheralDelegate> _shimDelegate;
    CBPeripheralState _shimState;
    NSArray *_shimServices;
}

- (instancetype)initWithIdentifier:(NSUUID *)identifier name:(NSString *)name {
    self = cbs_super_init(self, [CBPeripheral class]);
    if (self) {
        _shimIdentifier = identifier;
        _shimName = [name copy];
        _shimDelegate = nil;
        _shimState = CBPeripheralStateDisconnected;
        _shimServices = @[];
    }
    return self;
}

- (NSUUID *)identifier { return _shimIdentifier; }
- (NSString *)name { return _shimName; }
- (id<CBPeripheralDelegate>)delegate { return _shimDelegate; }
- (void)setDelegate:(id<CBPeripheralDelegate>)delegate { _shimDelegate = delegate; }
- (CBPeripheralState)state { return _shimState; }
- (NSArray *)services { return _shimServices; }
- (void)setServices:(NSArray *)services { _shimServices = [services copy] ?: @[]; }

- (void)cbs_updateName:(NSString *)name {
    _shimName = [name copy];
}

- (void)cbs_setState:(CBPeripheralState)state {
    _shimState = state;
}

- (void)readRSSI {
    CBSConnectionSend(@{@"type": @"readRSSI", @"id": _shimIdentifier.UUIDString});
}

- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {
    NSArray<NSString *> *uuids = serviceUUIDs ? cbs_uuid_strings(serviceUUIDs) : @[];
    CBSConnectionSend(@{@"type": @"discoverServices", @"id": _shimIdentifier.UUIDString, @"services": uuids});
}

- (void)discoverIncludedServices:(NSArray<CBUUID *> *)includedServiceUUIDs forService:(CBService *)service {
    CBSService *svc = [service isKindOfClass:[CBSService class]] ? (CBSService *)service : nil;
    if (!svc || !svc.shimId) {
        return;
    }
    NSArray<NSString *> *uuids = includedServiceUUIDs ? cbs_uuid_strings(includedServiceUUIDs) : @[];
    CBSConnectionSend(@{
        @"type": @"discoverIncludedServices",
        @"id": _shimIdentifier.UUIDString,
        @"serviceId": svc.shimId,
        @"services": uuids
    });
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

- (void)discoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic {
    CBSCharacteristic *chr = [characteristic isKindOfClass:[CBSCharacteristic class]] ? (CBSCharacteristic *)characteristic : nil;
    if (!chr || !chr.shimId) {
        return;
    }
    CBSConnectionSend(@{
        @"type": @"discoverDescriptors",
        @"id": _shimIdentifier.UUIDString,
        @"characteristicId": chr.shimId
    });
}

- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic {
    CBSCharacteristic *chr = [characteristic isKindOfClass:[CBSCharacteristic class]] ? (CBSCharacteristic *)characteristic : nil;
    if (!chr || !chr.shimId) {
        return;
    }
    CBSConnectionSend(@{@"type": @"read", @"id": _shimIdentifier.UUIDString, @"characteristicId": chr.shimId});
}

- (void)readValueForDescriptor:(CBDescriptor *)descriptor {
    CBSDescriptor *desc = [descriptor isKindOfClass:[CBSDescriptor class]] ? (CBSDescriptor *)descriptor : nil;
    if (!desc || !desc.shimId) {
        return;
    }
    CBSConnectionSend(@{
        @"type": @"readDescriptor",
        @"id": _shimIdentifier.UUIDString,
        @"descriptorId": desc.shimId
    });
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

- (void)writeValue:(NSData *)data forDescriptor:(CBDescriptor *)descriptor {
    CBSDescriptor *desc = [descriptor isKindOfClass:[CBSDescriptor class]] ? (CBSDescriptor *)descriptor : nil;
    if (!desc || !desc.shimId) {
        return;
    }
    NSString *b64 = data ? [data base64EncodedStringWithOptions:0] : @"";
    CBSConnectionSend(@{
        @"type": @"writeDescriptor",
        @"id": _shimIdentifier.UUIDString,
        @"descriptorId": desc.shimId,
        @"value": b64
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

- (BOOL)ancsAuthorized {
    return NO;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[CBSPeripheral class]]) return NO;
    return [_shimIdentifier isEqual:((CBSPeripheral *)object)->_shimIdentifier];
}

- (NSUInteger)hash {
    return _shimIdentifier.hash;
}

@end

#pragma mark - CBSService (subclass of CBService)

@implementation CBSService {
    CBUUID *_shimUUID;
    BOOL _shimPrimary;
    CBSPeripheral *_shimPeripheral;
    NSArray *_shimCharacteristics;
    NSArray *_shimIncludedServices;
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
        _shimIncludedServices = @[];
    }
    return self;
}

- (CBUUID *)UUID { return _shimUUID; }
- (BOOL)isPrimary { return _shimPrimary; }
- (CBPeripheral *)peripheral { return (CBPeripheral *)_shimPeripheral; }
- (NSArray *)includedServices { return _shimIncludedServices; }
- (NSArray *)characteristics { return _shimCharacteristics; }
- (void)cbs_setIncludedServices:(NSArray *)includedServices { _shimIncludedServices = [includedServices copy]; }
- (void)cbs_setCharacteristics:(NSArray *)characteristics { _shimCharacteristics = [characteristics copy]; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[CBSService class]]) return NO;
    return [_shimId isEqual:((CBSService *)object)->_shimId];
}

- (NSUInteger)hash {
    return _shimId.hash;
}

@end

#pragma mark - CBSCharacteristic (subclass of CBCharacteristic)

@implementation CBSCharacteristic {
    CBUUID *_shimUUID;
    CBCharacteristicProperties _shimProperties;
    NSData *_shimValue;
    BOOL _shimNotifying;
    CBSService *_shimService;
    NSArray *_shimDescriptors;
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
        _shimDescriptors = @[];
    }
    return self;
}

- (CBUUID *)UUID { return _shimUUID; }
- (CBCharacteristicProperties)properties { return _shimProperties; }
- (CBService *)service { return (CBService *)_shimService; }
- (NSArray *)descriptors { return _shimDescriptors; }

- (NSData *)value { return _shimValue; }
- (void)cbs_setValue:(NSData *)value { _shimValue = [value copy]; }

- (BOOL)isNotifying { return _shimNotifying; }
- (void)cbs_setNotifying:(BOOL)notifying { _shimNotifying = notifying; }
- (void)cbs_setDescriptors:(NSArray *)descriptors { _shimDescriptors = [descriptors copy]; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[CBSCharacteristic class]]) return NO;
    return [_shimId isEqual:((CBSCharacteristic *)object)->_shimId];
}

- (NSUInteger)hash {
    return _shimId.hash;
}

@end

#pragma mark - CBSDescriptor (subclass of CBDescriptor)

@implementation CBSDescriptor {
    CBUUID *_shimUUID;
    CBSCharacteristic *_shimCharacteristic;
    id _shimValue;
}

- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
            characteristic:(CBSCharacteristic *)characteristic {
    self = cbs_super_init(self, [CBDescriptor class]);
    if (self) {
        _shimId = [shimId copy];
        _shimUUID = uuid;
        _shimCharacteristic = characteristic;
        _shimValue = nil;
    }
    return self;
}

- (CBUUID *)UUID { return _shimUUID; }
- (CBCharacteristic *)characteristic { return (CBCharacteristic *)_shimCharacteristic; }
- (id)value { return _shimValue; }
- (void)cbs_setValue:(id)value { _shimValue = value; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[CBSDescriptor class]]) return NO;
    return [_shimId isEqual:((CBSDescriptor *)object)->_shimId];
}

- (NSUInteger)hash {
    return _shimId.hash;
}

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
- (void)readRSSI {}
- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {}
- (void)discoverIncludedServices:(NSArray<CBUUID *> *)includedServiceUUIDs forService:(CBService *)service {}
- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs forService:(CBService *)service {}
- (void)discoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic {}
- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic {}
- (void)readValueForDescriptor:(CBDescriptor *)descriptor {}
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type {}
- (void)writeValue:(NSData *)data forDescriptor:(CBDescriptor *)descriptor {}
- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic {}
- (void)openL2CAPChannel:(CBL2CAPPSM)PSM {}
- (NSInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type { return 0; }
- (BOOL)canSendWriteWithoutResponse { return NO; }
- (BOOL)ancsAuthorized { return NO; }
@end

@implementation CBSService
- (instancetype)initWithId:(NSString *)shimId uuid:(CBUUID *)uuid primary:(BOOL)primary peripheral:(CBSPeripheral *)peripheral { return nil; }
- (void)cbs_setCharacteristics:(NSArray *)characteristics {}
- (void)cbs_setIncludedServices:(NSArray *)includedServices {}
@end

@implementation CBSCharacteristic
- (instancetype)initWithId:(NSString *)shimId uuid:(CBUUID *)uuid properties:(CBCharacteristicProperties)properties service:(CBSService *)service { return nil; }
- (void)cbs_setValue:(NSData *)value {}
- (void)cbs_setNotifying:(BOOL)notifying {}
- (void)cbs_setDescriptors:(NSArray *)descriptors {}
@end

@implementation CBSDescriptor
- (instancetype)initWithId:(NSString *)shimId uuid:(CBUUID *)uuid characteristic:(CBSCharacteristic *)characteristic { return nil; }
- (void)cbs_setValue:(id)value {}
@end

@implementation CBSChannel
- (instancetype)initWithId:(NSString *)shimId psm:(CBL2CAPPSM)psm inputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream peer:(CBPeer *)peer { return nil; }
@end

#endif
