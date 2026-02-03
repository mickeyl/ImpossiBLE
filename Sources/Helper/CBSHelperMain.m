#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static const char *kCBSSocketPath = "/tmp/impossible.sock";
static void *kCBSServiceIdKey = &kCBSServiceIdKey;
static void *kCBSCharacteristicIdKey = &kCBSCharacteristicIdKey;

@interface CBSHelper : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate, NSStreamDelegate>
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) dispatch_queue_t cbQueue;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, CBPeripheral *> *peripherals;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBService *> *servicesById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBCharacteristic *> *characteristicsById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBL2CAPChannel *> *l2capById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *streamToL2capId;
@property(nonatomic, strong) NSArray<CBUUID *> *pendingServices;
@property(nonatomic, strong) NSDictionary *pendingOptions;
@property(nonatomic, assign) int clientFd;
@property(nonatomic, assign) uint64_t clientGeneration;
@end

@implementation CBSHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _cbQueue = dispatch_queue_create("impossible.cb", DISPATCH_QUEUE_SERIAL);
        _central = [[CBCentralManager alloc] initWithDelegate:self queue:_cbQueue options:nil];
        _peripherals = [NSMutableDictionary dictionary];
        _servicesById = [NSMutableDictionary dictionary];
        _characteristicsById = [NSMutableDictionary dictionary];
        _l2capById = [NSMutableDictionary dictionary];
        _streamToL2capId = [NSMutableDictionary dictionary];
        _clientFd = -1;
    }
    return self;
}

- (void)start {
    [self startSocketServer];
}

- (void)startSocketServer {
    int serverFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (serverFd < 0) {
        perror("socket");
        return;
    }

    unlink(kCBSSocketPath);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kCBSSocketPath, sizeof(addr.sun_path) - 1);

    if (bind(serverFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(serverFd);
        return;
    }
    if (listen(serverFd, 1) != 0) {
        perror("listen");
        close(serverFd);
        return;
    }

    NSLog(@"ImpossiBLE-Helper: listening on %s", kCBSSocketPath);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (1) {
            int client = accept(serverFd, NULL, NULL);
            if (client < 0) {
                perror("accept");
                continue;
            }
            int noSigPipe = 1;
            if (setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe)) != 0) {
                perror("setsockopt(SO_NOSIGPIPE)");
            }
            if (self.clientFd >= 0) {
                NSLog(@"ImpossiBLE-Helper: replacing existing client");
                [self handleClientDisconnectForFd:self.clientFd generation:self.clientGeneration];
            }
            NSLog(@"ImpossiBLE-Helper: client connected");
            self.clientFd = client;
            self.clientGeneration += 1;
            uint64_t generation = self.clientGeneration;
            [self startReaderForClient:client generation:generation];
        }
    });
}

- (void)startReaderForClient:(int)fd generation:(uint64_t)generation {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        while (1) {
            uint8_t tmp[2048];
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n <= 0) {
                NSLog(@"ImpossiBLE-Helper: client disconnected");
                [self handleClientDisconnectForFd:fd generation:generation];
                break;
            }
            [buffer appendBytes:tmp length:(NSUInteger)n];
            while (1) {
                const uint8_t *bytes = buffer.bytes;
                NSUInteger len = buffer.length;
                NSUInteger idx = NSNotFound;
                for (NSUInteger i = 0; i < len; i++) {
                    if (bytes[i] == '\n') {
                        idx = i;
                        break;
                    }
                }
                if (idx == NSNotFound) {
                    break;
                }
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, idx)];
                [buffer replaceBytesInRange:NSMakeRange(0, idx + 1) withBytes:NULL length:0];
                [self handleMessageLine:line];
            }
        }
    });
}

- (void)handleClientDisconnectForFd:(int)fd generation:(uint64_t)generation {
    if (fd < 0) {
        return;
    }
    if (generation != self.clientGeneration || fd != self.clientFd) {
        return;
    }
    self.clientFd = -1;
    close(fd);

    NSArray<CBPeripheral *> *peripherals = [self.peripherals allValues];
    NSArray<CBL2CAPChannel *> *channels = [self.l2capById allValues];

    [self.peripherals removeAllObjects];
    [self.servicesById removeAllObjects];
    [self.characteristicsById removeAllObjects];
    [self.l2capById removeAllObjects];
    [self.streamToL2capId removeAllObjects];
    self.pendingServices = nil;
    self.pendingOptions = nil;

    dispatch_async(self.cbQueue, ^{
        [self.central stopScan];
        for (CBPeripheral *peripheral in peripherals) {
            [self.central cancelPeripheralConnection:peripheral];
        }
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        for (CBL2CAPChannel *channel in channels) {
            channel.inputStream.delegate = nil;
            channel.outputStream.delegate = nil;
            [channel.inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            [channel.outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            [channel.inputStream close];
            [channel.outputStream close];
        }
    });
}

- (void)handleMessageLine:(NSData *)line {
    if (line.length == 0) {
        return;
    }
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *msg = (NSDictionary *)obj;
    NSString *type = msg[@"type"];
    if (![type isKindOfClass:[NSString class]]) {
        return;
    }
    NSLog(@"ImpossiBLE-Helper: recv type=%@", type);

    if ([type isEqualToString:@"scan"]) {
        NSArray *services = msg[@"services"];
        NSDictionary *options = msg[@"options"];
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        if ([services isKindOfClass:[NSArray class]]) {
            for (id item in services) {
                if ([item isKindOfClass:[NSString class]]) {
                    [uuids addObject:[CBUUID UUIDWithString:item]];
                }
            }
        }
        if (![options isKindOfClass:[NSDictionary class]]) {
            options = @{};
        }
        [self startScanWithServices:uuids options:options];
        return;
    }

    if ([type isEqualToString:@"stopScan"]) {
        dispatch_async(self.cbQueue, ^{
            [self.central stopScan];
        });
        return;
    }

    if ([type isEqualToString:@"connect"]) {
        NSString *uuidStr = msg[@"id"];
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        CBPeripheral *peripheral = self.peripherals[uuid];
        if (!peripheral) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            peripheral.delegate = self;
            [self.central connectPeripheral:peripheral options:nil];
        });
        return;
    }

    if ([type isEqualToString:@"cancel"]) {
        NSString *uuidStr = msg[@"id"];
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        CBPeripheral *peripheral = self.peripherals[uuid];
        if (!peripheral) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            [self.central cancelPeripheralConnection:peripheral];
        });
        return;
    }

    if ([type isEqualToString:@"discoverServices"]) {
        NSString *uuidStr = msg[@"id"];
        NSArray *services = msg[@"services"];
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        CBPeripheral *peripheral = self.peripherals[uuid];
        if (!peripheral) {
            return;
        }
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        if ([services isKindOfClass:[NSArray class]]) {
            for (id item in services) {
                if ([item isKindOfClass:[NSString class]]) {
                    [uuids addObject:[CBUUID UUIDWithString:item]];
                }
            }
        }
        dispatch_async(self.cbQueue, ^{
            peripheral.delegate = self;
            NSArray<CBUUID *> *svc = uuids.count > 0 ? uuids : nil;
            [peripheral discoverServices:svc];
        });
        return;
    }

    if ([type isEqualToString:@"discoverCharacteristics"]) {
        NSString *serviceId = msg[@"serviceId"];
        NSArray *chars = msg[@"characteristics"];
        if (![serviceId isKindOfClass:[NSString class]]) {
            return;
        }
        CBService *service = self.servicesById[serviceId];
        if (!service) {
            return;
        }
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        if ([chars isKindOfClass:[NSArray class]]) {
            for (id item in chars) {
                if ([item isKindOfClass:[NSString class]]) {
                    [uuids addObject:[CBUUID UUIDWithString:item]];
                }
            }
        }
        dispatch_async(self.cbQueue, ^{
            NSArray<CBUUID *> *svc = uuids.count > 0 ? uuids : nil;
            [service.peripheral discoverCharacteristics:svc forService:service];
        });
        return;
    }

    if ([type isEqualToString:@"read"]) {
        NSString *chId = msg[@"characteristicId"];
        if (![chId isKindOfClass:[NSString class]]) {
            return;
        }
        CBCharacteristic *chr = self.characteristicsById[chId];
        if (!chr) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            [chr.service.peripheral readValueForCharacteristic:chr];
        });
        return;
    }

    if ([type isEqualToString:@"write"]) {
        NSString *chId = msg[@"characteristicId"];
        NSString *valueB64 = msg[@"value"];
        NSNumber *writeType = msg[@"writeType"] ?: @0;
        if (![chId isKindOfClass:[NSString class]]) {
            return;
        }
        CBCharacteristic *chr = self.characteristicsById[chId];
        if (!chr) {
            return;
        }
        NSData *data = nil;
        if ([valueB64 isKindOfClass:[NSString class]] && valueB64.length > 0) {
            data = [[NSData alloc] initWithBase64EncodedString:valueB64 options:0];
        } else {
            data = [NSData data];
        }
        CBCharacteristicWriteType wt = writeType.integerValue == 1 ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
        dispatch_async(self.cbQueue, ^{
            [chr.service.peripheral writeValue:data forCharacteristic:chr type:wt];
        });
        return;
    }

    if ([type isEqualToString:@"setNotify"]) {
        NSString *chId = msg[@"characteristicId"];
        NSNumber *enabled = msg[@"enabled"] ?: @0;
        if (![chId isKindOfClass:[NSString class]]) {
            return;
        }
        CBCharacteristic *chr = self.characteristicsById[chId];
        if (!chr) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            [chr.service.peripheral setNotifyValue:enabled.boolValue forCharacteristic:chr];
        });
        return;
    }

    if ([type isEqualToString:@"openL2CAP"]) {
        NSString *uuidStr = msg[@"id"];
        NSNumber *psmNum = msg[@"psm"] ?: @0;
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        CBPeripheral *peripheral = self.peripherals[uuid];
        if (!peripheral) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            peripheral.delegate = self;
            [peripheral openL2CAPChannel:(CBL2CAPPSM)psmNum.unsignedShortValue];
        });
        return;
    }

    if ([type isEqualToString:@"l2capWrite"]) {
        NSString *chanId = msg[@"channelId"];
        NSString *valueB64 = msg[@"value"];
        if (![chanId isKindOfClass:[NSString class]] || ![valueB64 isKindOfClass:[NSString class]]) {
            return;
        }
        CBL2CAPChannel *channel = self.l2capById[chanId];
        if (!channel) {
            return;
        }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:valueB64 options:0];
        if (!data) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [channel.outputStream write:data.bytes maxLength:data.length];
        });
        return;
    }

    if ([type isEqualToString:@"l2capClose"]) {
        NSString *chanId = msg[@"channelId"];
        if (![chanId isKindOfClass:[NSString class]]) {
            return;
        }
        CBL2CAPChannel *channel = self.l2capById[chanId];
        if (!channel) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            channel.inputStream.delegate = nil;
            channel.outputStream.delegate = nil;
            [channel.inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            [channel.outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            [channel.inputStream close];
            [channel.outputStream close];
        });
        [self.l2capById removeObjectForKey:chanId];
        [self removeStreamMappingsForChannelId:chanId];
        [self sendMessage:@{@"type": @"l2capClosed", @"channelId": chanId}];
        return;
    }
}

- (void)startScanWithServices:(NSArray<CBUUID *> *)services options:(NSDictionary *)options {
    dispatch_async(self.cbQueue, ^{
        if (self.central.state == CBManagerStatePoweredOn) {
            NSArray<CBUUID *> *svc = services.count > 0 ? services : nil;
            [self.central scanForPeripheralsWithServices:svc options:options];
            NSLog(@"ImpossiBLE-Helper: scanning");
        } else {
            self.pendingServices = services;
            self.pendingOptions = options;
            NSLog(@"ImpossiBLE-Helper: deferring scan until powered on");
        }
    });
}

- (void)sendMessage:(NSDictionary *)msg {
    int fd = self.clientFd;
    uint64_t generation = self.clientGeneration;
    if (fd < 0) {
        return;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:&error];
    if (!data) {
        return;
    }
    if (![self writeAllToFd:fd bytes:data.bytes length:data.length]) {
        [self handleClientDisconnectForFd:fd generation:generation];
        return;
    }
    if (![self writeAllToFd:fd bytes:"\n" length:1]) {
        [self handleClientDisconnectForFd:fd generation:generation];
        return;
    }
}

#pragma mark - Helpers

- (void)removeStreamMappingsForChannelId:(NSString *)chanId {
    if (!chanId) {
        return;
    }
    NSArray *keys = [self.streamToL2capId allKeysForObject:chanId];
    for (NSString *key in keys) {
        [self.streamToL2capId removeObjectForKey:key];
    }
}

- (BOOL)writeAllToFd:(int)fd bytes:(const void *)bytes length:(size_t)length {
    const uint8_t *ptr = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t n = write(fd, ptr, remaining);
        if (n <= 0) {
            return NO;
        }
        ptr += (size_t)n;
        remaining -= (size_t)n;
    }
    return YES;
}

- (NSString *)serviceIdForPeripheral:(CBPeripheral *)peripheral service:(CBService *)service index:(NSUInteger)index {
    return [NSString stringWithFormat:@"%@:%@:%lu",
            peripheral.identifier.UUIDString,
            service.UUID.UUIDString,
            (unsigned long)index];
}

- (NSString *)characteristicIdForServiceId:(NSString *)serviceId characteristic:(CBCharacteristic *)characteristic index:(NSUInteger)index {
    return [NSString stringWithFormat:@"%@:%@:%lu",
            serviceId,
            characteristic.UUID.UUIDString,
            (unsigned long)index];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSLog(@"ImpossiBLE-Helper: state = %ld", (long)central.state);
    if (central.state == CBManagerStatePoweredOn && self.pendingServices) {
        NSArray<CBUUID *> *services = self.pendingServices;
        NSDictionary *options = self.pendingOptions ?: @{};
        self.pendingServices = nil;
        self.pendingOptions = nil;
        [central scanForPeripheralsWithServices:(services.count > 0 ? services : nil) options:options];
        NSLog(@"ImpossiBLE-Helper: deferred scan started");
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (!peripheral.identifier) {
        return;
    }
    self.peripherals[peripheral.identifier] = peripheral;
    peripheral.delegate = self;
    NSString *name = peripheral.name ?: @"";
    NSString *advName = advertisementData[CBAdvertisementDataLocalNameKey];
    NSDictionary *adv = advName ? @{@"localName": advName} : @{};
    [self sendMessage:@{
        @"type": @"didDiscover",
        @"id": peripheral.identifier.UUIDString,
        @"name": name,
        @"rssi": RSSI ?: @0,
        @"adv": adv
    }];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (!peripheral.identifier) {
        return;
    }
    [self sendMessage:@{@"type": @"didConnect", @"id": peripheral.identifier.UUIDString}];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{@"type": @"didFailConnect", @"id": peripheral.identifier.UUIDString, @"error": errStr}];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{@"type": @"didDisconnect", @"id": peripheral.identifier.UUIDString, @"error": errStr}];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSMutableArray *servicesPayload = [NSMutableArray array];
    NSArray<CBService *> *services = peripheral.services ?: @[];
    [services enumerateObjectsUsingBlock:^(CBService *svc, NSUInteger idx, BOOL *stop) {
        NSString *svcId = [self serviceIdForPeripheral:peripheral service:svc index:idx];
        objc_setAssociatedObject(svc, kCBSServiceIdKey, svcId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.servicesById[svcId] = svc;
        [servicesPayload addObject:@{
            @"id": svcId,
            @"uuid": svc.UUID.UUIDString ?: @"",
            @"primary": @(svc.isPrimary)
        }];
    }];
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didDiscoverServices",
        @"id": peripheral.identifier.UUIDString,
        @"services": servicesPayload,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *serviceId = objc_getAssociatedObject(service, kCBSServiceIdKey);
    if (![serviceId isKindOfClass:[NSString class]]) {
        return;
    }
    NSMutableArray *charsPayload = [NSMutableArray array];
    NSArray<CBCharacteristic *> *chars = service.characteristics ?: @[];
    [chars enumerateObjectsUsingBlock:^(CBCharacteristic *chr, NSUInteger idx, BOOL *stop) {
        NSString *chId = [self characteristicIdForServiceId:serviceId characteristic:chr index:idx];
        objc_setAssociatedObject(chr, kCBSCharacteristicIdKey, chId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.characteristicsById[chId] = chr;
        [charsPayload addObject:@{
            @"id": chId,
            @"uuid": chr.UUID.UUIDString ?: @"",
            @"properties": @(chr.properties)
        }];
    }];
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didDiscoverCharacteristics",
        @"id": peripheral.identifier.UUIDString,
        @"serviceId": serviceId,
        @"characteristics": charsPayload,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *chId = objc_getAssociatedObject(characteristic, kCBSCharacteristicIdKey);
    if (![chId isKindOfClass:[NSString class]]) {
        return;
    }
    NSString *b64 = characteristic.value ? [characteristic.value base64EncodedStringWithOptions:0] : @"";
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didUpdateValue",
        @"id": peripheral.identifier.UUIDString,
        @"characteristicId": chId,
        @"value": b64,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *chId = objc_getAssociatedObject(characteristic, kCBSCharacteristicIdKey);
    if (![chId isKindOfClass:[NSString class]]) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didWriteValue",
        @"id": peripheral.identifier.UUIDString,
        @"characteristicId": chId,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *chId = objc_getAssociatedObject(characteristic, kCBSCharacteristicIdKey);
    if (![chId isKindOfClass:[NSString class]]) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didUpdateNotification",
        @"id": peripheral.identifier.UUIDString,
        @"characteristicId": chId,
        @"enabled": @(characteristic.isNotifying),
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didOpenL2CAPChannel:(CBL2CAPChannel *)channel error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    if (error || !channel) {
        [self sendMessage:@{
            @"type": @"didOpenL2CAP",
            @"id": peripheral.identifier.UUIDString,
            @"channelId": @"",
            @"psm": @0,
            @"error": errStr
        }];
        return;
    }

    NSString *chanId = [NSString stringWithFormat:@"%@:%u:%p",
                        peripheral.identifier.UUIDString,
                        channel.PSM,
                        channel];
    self.l2capById[chanId] = channel;

    dispatch_async(dispatch_get_main_queue(), ^{
        channel.inputStream.delegate = (id<NSStreamDelegate>)self;
        channel.outputStream.delegate = (id<NSStreamDelegate>)self;
        [channel.inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [channel.outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [channel.inputStream open];
        [channel.outputStream open];
        self.streamToL2capId[[NSString stringWithFormat:@"%p", channel.inputStream]] = chanId;
        self.streamToL2capId[[NSString stringWithFormat:@"%p", channel.outputStream]] = chanId;
    });

    [self sendMessage:@{
        @"type": @"didOpenL2CAP",
        @"id": peripheral.identifier.UUIDString,
        @"channelId": chanId,
        @"psm": @(channel.PSM),
        @"error": errStr
    }];
}

#pragma mark - NSStreamDelegate (L2CAP)

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    NSString *key = [NSString stringWithFormat:@"%p", aStream];
    NSString *chanId = self.streamToL2capId[key];
    if (!chanId) {
        return;
    }

    if (eventCode == NSStreamEventHasBytesAvailable) {
        uint8_t buf[2048];
        NSInputStream *inStream = (NSInputStream *)aStream;
        NSInteger n = [inStream read:buf maxLength:sizeof(buf)];
        if (n > 0) {
            NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
            NSString *b64 = [data base64EncodedStringWithOptions:0];
            [self sendMessage:@{@"type": @"l2capData", @"channelId": chanId, @"value": b64}];
        }
        return;
    }

    if (eventCode == NSStreamEventEndEncountered || eventCode == NSStreamEventErrorOccurred) {
        [self sendMessage:@{@"type": @"l2capClosed", @"channelId": chanId}];
        CBL2CAPChannel *channel = self.l2capById[chanId];
        if (channel) {
            dispatch_async(dispatch_get_main_queue(), ^{
                channel.inputStream.delegate = nil;
                channel.outputStream.delegate = nil;
                [channel.inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
                [channel.outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
                [channel.inputStream close];
                [channel.outputStream close];
            });
        }
        [self.l2capById removeObjectForKey:chanId];
        [self removeStreamMappingsForChannelId:chanId];
        return;
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSLog(@"ImpossiBLE-Helper: starting");
        CBSHelper *helper = [[CBSHelper alloc] init];
        [helper start];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
