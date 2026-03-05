#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <signal.h>
#import <unistd.h>

static const char *kCBSSocketPath = "/tmp/impossible.sock";
static void *kCBSServiceIdKey = &kCBSServiceIdKey;
static void *kCBSCharacteristicIdKey = &kCBSCharacteristicIdKey;
static void *kCBSDescriptorIdKey = &kCBSDescriptorIdKey;

@interface CBSHelper : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate, NSStreamDelegate>
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) dispatch_queue_t cbQueue;
@property(nonatomic, strong) dispatch_queue_t ioQueue;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, CBPeripheral *> *peripherals;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBService *> *servicesById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBCharacteristic *> *characteristicsById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBDescriptor *> *descriptorsById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBL2CAPChannel *> *l2capById;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *streamToL2capId;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, dispatch_source_t> *pendingL2capOpenTimers;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, NSSet<CBUUID *> *> *pendingServiceFilters;
@property(nonatomic, strong) NSArray<CBUUID *> *pendingServices;
@property(nonatomic, strong) NSDictionary *pendingOptions;
@property(nonatomic, strong) NSMutableSet<NSUUID *> *seenScanPeripherals;
@property(nonatomic, assign) BOOL scanShouldDeduplicate;
@property(nonatomic, assign) int clientFd;
@property(nonatomic, assign) uint64_t clientGeneration;
@end

@implementation CBSHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _cbQueue = dispatch_queue_create("impossible.cb", DISPATCH_QUEUE_SERIAL);
        _ioQueue = dispatch_queue_create("impossible.io", DISPATCH_QUEUE_SERIAL);
        _central = [[CBCentralManager alloc] initWithDelegate:self queue:_cbQueue options:nil];
        _peripherals = [NSMutableDictionary dictionary];
        _servicesById = [NSMutableDictionary dictionary];
        _characteristicsById = [NSMutableDictionary dictionary];
        _descriptorsById = [NSMutableDictionary dictionary];
        _l2capById = [NSMutableDictionary dictionary];
        _streamToL2capId = [NSMutableDictionary dictionary];
        _pendingL2capOpenTimers = [NSMutableDictionary dictionary];
        _pendingServiceFilters = [NSMutableDictionary dictionary];
        _seenScanPeripherals = [NSMutableSet set];
        _scanShouldDeduplicate = YES;
        _clientFd = -1;
    }
    return self;
}

- (NSDictionary *)scanOptionsFromWire:(NSDictionary *)wireOptions {
    NSDictionary *options = [wireOptions isKindOfClass:[NSDictionary class]] ? wireOptions : @{};
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];

    id allowDuplicates = options[CBCentralManagerScanOptionAllowDuplicatesKey];
    if ([allowDuplicates respondsToSelector:@selector(boolValue)]) {
        normalized[CBCentralManagerScanOptionAllowDuplicatesKey] = @([allowDuplicates boolValue]);
    }
    if (!normalized[CBCentralManagerScanOptionAllowDuplicatesKey]) {
        // Match CoreBluetooth's documented default: duplicate discoveries are coalesced.
        normalized[CBCentralManagerScanOptionAllowDuplicatesKey] = @NO;
    }

    id solicited = options[CBCentralManagerScanOptionSolicitedServiceUUIDsKey];
    if ([solicited isKindOfClass:[NSArray class]]) {
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        for (id item in (NSArray *)solicited) {
            if ([item isKindOfClass:[CBUUID class]]) {
                [uuids addObject:item];
            } else if ([item isKindOfClass:[NSString class]]) {
                CBUUID *uuid = [CBUUID UUIDWithString:item];
                if (uuid) {
                    [uuids addObject:uuid];
                }
            }
        }
        if (uuids.count > 0) {
            normalized[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = uuids;
        }
    }
    return normalized;
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
            dispatch_async(self.ioQueue, ^{
                if (self.clientFd >= 0) {
                    NSLog(@"ImpossiBLE-Helper: replacing existing client");
                    [self handleClientDisconnectLockedForFd:self.clientFd generation:self.clientGeneration];
                }
                NSLog(@"ImpossiBLE-Helper: client connected");
                self.clientFd = client;
                self.clientGeneration += 1;
                uint64_t generation = self.clientGeneration;
                [self startReaderForClient:client generation:generation];
            });
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
                dispatch_async(self.ioQueue, ^{
                    NSLog(@"ImpossiBLE-Helper: client disconnected");
                    [self handleClientDisconnectLockedForFd:fd generation:generation];
                });
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
    dispatch_async(self.ioQueue, ^{
        [self handleClientDisconnectLockedForFd:fd generation:generation];
    });
}

- (void)handleClientDisconnectLockedForFd:(int)fd generation:(uint64_t)generation {
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
    [self.descriptorsById removeAllObjects];
    [self.l2capById removeAllObjects];
    [self.streamToL2capId removeAllObjects];
    for (dispatch_source_t timer in [self.pendingL2capOpenTimers allValues]) {
        dispatch_source_cancel(timer);
    }
    [self.pendingL2capOpenTimers removeAllObjects];
    [self.seenScanPeripherals removeAllObjects];
    self.scanShouldDeduplicate = YES;
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

- (void)cancelPendingL2capOpenForPeripheralId:(NSUUID *)peripheralId {
    if (!peripheralId) {
        return;
    }
    dispatch_source_t timer = self.pendingL2capOpenTimers[peripheralId];
    if (!timer) {
        return;
    }
    [self.pendingL2capOpenTimers removeObjectForKey:peripheralId];
    dispatch_source_cancel(timer);
}

- (void)schedulePendingL2capOpenTimeoutForPeripheral:(CBPeripheral *)peripheral psm:(CBL2CAPPSM)psm {
    NSUUID *peripheralId = peripheral.identifier;
    if (!peripheralId) {
        return;
    }
    [self cancelPendingL2capOpenForPeripheralId:peripheralId];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.cbQueue);
    if (!timer) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER,
        (uint64_t)(100 * NSEC_PER_MSEC)
    );
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_source_t activeTimer = strongSelf.pendingL2capOpenTimers[peripheralId];
        if (activeTimer != timer) {
            return;
        }
        [strongSelf.pendingL2capOpenTimers removeObjectForKey:peripheralId];
        dispatch_source_cancel(timer);
        [strongSelf sendMessage:@{
            @"type": @"didOpenL2CAP",
            @"id": peripheralId.UUIDString,
            @"channelId": @"",
            @"psm": @(psm),
            @"error": @"Timeout opening L2CAP channel"
        }];
    });
    self.pendingL2capOpenTimers[peripheralId] = timer;
    dispatch_resume(timer);
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

    if ([type isEqualToString:@"registerForConnectionEvents"]) {
        NSDictionary *options = msg[@"options"];
        dispatch_async(self.cbQueue, ^{
#if TARGET_OS_IOS
            if (@available(iOS 13.0, *)) {
                NSDictionary *eventOptions = [options isKindOfClass:[NSDictionary class]] ? options : nil;
                [self.central registerForConnectionEventsWithOptions:eventOptions];
            }
#endif
        });
        return;
    }

    if ([type isEqualToString:@"scan"]) {
        NSArray *services = msg[@"services"];
        NSDictionary *options = [self scanOptionsFromWire:msg[@"options"]];
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        if ([services isKindOfClass:[NSArray class]]) {
            for (id item in services) {
                if ([item isKindOfClass:[NSString class]]) {
                    CBUUID *uuid = [CBUUID UUIDWithString:item];
                    if (uuid) {
                        [uuids addObject:uuid];
                    }
                }
            }
        }
        [self startScanWithServices:uuids options:options];
        return;
    }

    if ([type isEqualToString:@"stopScan"]) {
        dispatch_async(self.cbQueue, ^{
            [self.central stopScan];
            [self.seenScanPeripherals removeAllObjects];
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

    if ([type isEqualToString:@"readRSSI"]) {
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
            [peripheral readRSSI];
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
                    CBUUID *uuid = [CBUUID UUIDWithString:item];
                    if (uuid) {
                        [uuids addObject:uuid];
                    }
                }
            }
        }
        if (uuids.count > 0) {
            self.pendingServiceFilters[uuid] = [NSSet setWithArray:uuids];
        } else {
            [self.pendingServiceFilters removeObjectForKey:uuid];
        }
        dispatch_async(self.cbQueue, ^{
            peripheral.delegate = self;
            NSArray<CBUUID *> *svc = uuids.count > 0 ? uuids : nil;
            [peripheral discoverServices:svc];
        });
        return;
    }

    if ([type isEqualToString:@"discoverIncludedServices"]) {
        NSString *serviceId = msg[@"serviceId"];
        NSArray *services = msg[@"services"];
        if (![serviceId isKindOfClass:[NSString class]]) {
            return;
        }
        CBService *service = self.servicesById[serviceId];
        if (!service) {
            return;
        }
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        if ([services isKindOfClass:[NSArray class]]) {
            for (id item in services) {
                if ([item isKindOfClass:[NSString class]]) {
                    CBUUID *uuid = [CBUUID UUIDWithString:item];
                    if (uuid) {
                        [uuids addObject:uuid];
                    }
                }
            }
        }
        dispatch_async(self.cbQueue, ^{
            NSArray<CBUUID *> *svc = uuids.count > 0 ? uuids : nil;
            [service.peripheral discoverIncludedServices:svc forService:service];
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
                    CBUUID *uuid = [CBUUID UUIDWithString:item];
                    if (uuid) {
                        [uuids addObject:uuid];
                    }
                }
            }
        }
        dispatch_async(self.cbQueue, ^{
            NSArray<CBUUID *> *svc = uuids.count > 0 ? uuids : nil;
            [service.peripheral discoverCharacteristics:svc forService:service];
        });
        return;
    }

    if ([type isEqualToString:@"discoverDescriptors"]) {
        NSString *chId = msg[@"characteristicId"];
        if (![chId isKindOfClass:[NSString class]]) {
            return;
        }
        CBCharacteristic *chr = self.characteristicsById[chId];
        if (!chr) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            [chr.service.peripheral discoverDescriptorsForCharacteristic:chr];
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

    if ([type isEqualToString:@"readDescriptor"]) {
        NSString *descriptorId = msg[@"descriptorId"];
        if (![descriptorId isKindOfClass:[NSString class]]) {
            return;
        }
        CBDescriptor *descriptor = self.descriptorsById[descriptorId];
        if (!descriptor) {
            return;
        }
        dispatch_async(self.cbQueue, ^{
            [descriptor.characteristic.service.peripheral readValueForDescriptor:descriptor];
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

    if ([type isEqualToString:@"writeDescriptor"]) {
        NSString *descriptorId = msg[@"descriptorId"];
        NSString *valueB64 = msg[@"value"];
        if (![descriptorId isKindOfClass:[NSString class]]) {
            return;
        }
        CBDescriptor *descriptor = self.descriptorsById[descriptorId];
        if (!descriptor) {
            return;
        }
        NSData *data = nil;
        if ([valueB64 isKindOfClass:[NSString class]] && valueB64.length > 0) {
            data = [[NSData alloc] initWithBase64EncodedString:valueB64 options:0];
        } else {
            data = [NSData data];
        }
        dispatch_async(self.cbQueue, ^{
            [descriptor.characteristic.service.peripheral writeValue:data forDescriptor:descriptor];
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
            CBL2CAPPSM psm = (CBL2CAPPSM)psmNum.unsignedShortValue;
            [self schedulePendingL2capOpenTimeoutForPeripheral:peripheral psm:psm];
            [peripheral openL2CAPChannel:psm];
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
        BOOL allowDuplicates = [options[CBCentralManagerScanOptionAllowDuplicatesKey] boolValue];
        self.scanShouldDeduplicate = !allowDuplicates;
        [self.seenScanPeripherals removeAllObjects];
        if (self.central.state == CBManagerStatePoweredOn) {
            NSArray<CBUUID *> *svc = services.count > 0 ? services : nil;
            [self.central scanForPeripheralsWithServices:svc options:options];
            NSLog(@"ImpossiBLE-Helper: scanning (allowDuplicates=%@)",
                  allowDuplicates ? @"YES" : @"NO");
        } else {
            self.pendingServices = services;
            self.pendingOptions = options;
            NSLog(@"ImpossiBLE-Helper: deferring scan until powered on");
        }
    });
}

- (void)sendMessage:(NSDictionary *)msg {
    dispatch_async(self.ioQueue, ^{
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
            [self handleClientDisconnectLockedForFd:fd generation:generation];
            return;
        }
        if (![self writeAllToFd:fd bytes:"\n" length:1]) {
            [self handleClientDisconnectLockedForFd:fd generation:generation];
            return;
        }
    });
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

- (NSString *)descriptorIdForCharacteristicId:(NSString *)characteristicId descriptor:(CBDescriptor *)descriptor index:(NSUInteger)index {
    return [NSString stringWithFormat:@"%@:%@:%lu",
            characteristicId,
            descriptor.UUID.UUIDString,
            (unsigned long)index];
}

- (id)jsonSafeDescriptorValue:(id)value descriptorValueB64Out:(NSString **)valueB64Out {
    if (valueB64Out) {
        *valueB64Out = @"";
    }
    if (!value || value == [NSNull null]) {
        return [NSNull null];
    }
    if ([value isKindOfClass:[NSData class]]) {
        if (valueB64Out) {
            *valueB64Out = [(NSData *)value base64EncodedStringWithOptions:0];
        }
        return [NSNull null];
    }
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSNull class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
        if ([NSJSONSerialization isValidJSONObject:value]) {
            return value;
        }
    }
    return [value description] ?: @"";
}

- (void)sendDisconnectForPeripheral:(CBPeripheral *)peripheral
                          timestamp:(CFAbsoluteTime)timestamp
                     isReconnecting:(BOOL)isReconnecting
                              error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didDisconnect",
        @"id": peripheral.identifier.UUIDString,
        @"error": errStr,
        @"timestamp": @(timestamp),
        @"isReconnecting": @(isReconnecting)
    }];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSLog(@"ImpossiBLE-Helper: state = %ld", (long)central.state);
    if (central.state == CBManagerStatePoweredOn && self.pendingServices) {
        NSArray<CBUUID *> *services = self.pendingServices;
        NSDictionary *options = self.pendingOptions ?: @{};
        self.pendingServices = nil;
        self.pendingOptions = nil;
        self.scanShouldDeduplicate = ![options[CBCentralManagerScanOptionAllowDuplicatesKey] boolValue];
        [self.seenScanPeripherals removeAllObjects];
        [central scanForPeripheralsWithServices:(services.count > 0 ? services : nil) options:options];
        NSLog(@"ImpossiBLE-Helper: deferred scan started");
    }
}

- (void)centralManager:(CBCentralManager *)central willRestoreState:(NSDictionary<NSString *,id> *)dict {
    NSMutableArray *peripheralIds = [NSMutableArray array];
    NSArray<CBPeripheral *> *peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey];
    if ([peripherals isKindOfClass:[NSArray class]]) {
        for (CBPeripheral *peripheral in peripherals) {
            if (![peripheral isKindOfClass:[CBPeripheral class]] || !peripheral.identifier) {
                continue;
            }
            self.peripherals[peripheral.identifier] = peripheral;
            peripheral.delegate = self;
            [peripheralIds addObject:peripheral.identifier.UUIDString];
        }
    }

    NSMutableArray *scanServices = [NSMutableArray array];
    NSArray *rawServices = dict[CBCentralManagerRestoredStateScanServicesKey];
    if ([rawServices isKindOfClass:[NSArray class]]) {
        for (id item in rawServices) {
            if ([item isKindOfClass:[CBUUID class]]) {
                NSString *uuid = ((CBUUID *)item).UUIDString;
                if (uuid.length > 0) {
                    [scanServices addObject:uuid];
                }
            } else if ([item isKindOfClass:[NSString class]]) {
                [scanServices addObject:item];
            }
        }
    }

    NSDictionary *scanOptions = [self scanOptionsFromWire:dict[CBCentralManagerRestoredStateScanOptionsKey]];

    [self sendMessage:@{
        @"type": @"didRestoreState",
        @"peripheralIds": peripheralIds,
        @"scanServices": scanServices,
        @"scanOptions": scanOptions ?: @{}
    }];
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (!peripheral.identifier) {
        return;
    }
    if (self.scanShouldDeduplicate && [self.seenScanPeripherals containsObject:peripheral.identifier]) {
        return;
    }
    if (self.scanShouldDeduplicate) {
        [self.seenScanPeripherals addObject:peripheral.identifier];
    }
    self.peripherals[peripheral.identifier] = peripheral;
    peripheral.delegate = self;
    NSString *advName = [advertisementData[CBAdvertisementDataLocalNameKey] isKindOfClass:[NSString class]]
        ? advertisementData[CBAdvertisementDataLocalNameKey]
        : nil;
    NSString *name = peripheral.name ?: advName ?: @"";

    NSMutableDictionary *adv = [NSMutableDictionary dictionary];
    if (advName.length > 0) {
        adv[CBAdvertisementDataLocalNameKey] = advName;
    }

    id connectable = advertisementData[CBAdvertisementDataIsConnectable];
    if ([connectable respondsToSelector:@selector(boolValue)]) {
        adv[CBAdvertisementDataIsConnectable] = @([connectable boolValue]);
    }

    NSArray *serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if ([serviceUUIDs isKindOfClass:[NSArray class]]) {
        NSMutableArray *serialized = [NSMutableArray array];
        for (id item in serviceUUIDs) {
            if ([item isKindOfClass:[CBUUID class]]) {
                NSString *uuid = ((CBUUID *)item).UUIDString;
                if (uuid.length > 0) {
                    [serialized addObject:uuid];
                }
            } else if ([item isKindOfClass:[NSString class]]) {
                [serialized addObject:item];
            }
        }
        if (serialized.count > 0) {
            adv[CBAdvertisementDataServiceUUIDsKey] = serialized;
        }
    }

    NSArray *overflowUUIDs = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey];
    if ([overflowUUIDs isKindOfClass:[NSArray class]]) {
        NSMutableArray *serialized = [NSMutableArray array];
        for (id item in overflowUUIDs) {
            if ([item isKindOfClass:[CBUUID class]]) {
                NSString *uuid = ((CBUUID *)item).UUIDString;
                if (uuid.length > 0) {
                    [serialized addObject:uuid];
                }
            } else if ([item isKindOfClass:[NSString class]]) {
                [serialized addObject:item];
            }
        }
        if (serialized.count > 0) {
            adv[CBAdvertisementDataOverflowServiceUUIDsKey] = serialized;
        }
    }

    NSArray *solicitedUUIDs = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey];
    if ([solicitedUUIDs isKindOfClass:[NSArray class]]) {
        NSMutableArray *serialized = [NSMutableArray array];
        for (id item in solicitedUUIDs) {
            if ([item isKindOfClass:[CBUUID class]]) {
                NSString *uuid = ((CBUUID *)item).UUIDString;
                if (uuid.length > 0) {
                    [serialized addObject:uuid];
                }
            } else if ([item isKindOfClass:[NSString class]]) {
                [serialized addObject:item];
            }
        }
        if (serialized.count > 0) {
            adv[CBAdvertisementDataSolicitedServiceUUIDsKey] = serialized;
        }
    }

    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if ([manufacturerData isKindOfClass:[NSData class]] && manufacturerData.length > 0) {
        adv[CBAdvertisementDataManufacturerDataKey] = [manufacturerData base64EncodedStringWithOptions:0];
    }

    NSDictionary *serviceData = advertisementData[CBAdvertisementDataServiceDataKey];
    if ([serviceData isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *serialized = [NSMutableDictionary dictionary];
        for (id key in serviceData) {
            CBUUID *uuid = [key isKindOfClass:[CBUUID class]] ? (CBUUID *)key : nil;
            NSData *value = [serviceData[key] isKindOfClass:[NSData class]] ? serviceData[key] : nil;
            if (uuid.UUIDString.length > 0 && value.length > 0) {
                serialized[uuid.UUIDString] = [value base64EncodedStringWithOptions:0];
            }
        }
        if (serialized.count > 0) {
            adv[CBAdvertisementDataServiceDataKey] = serialized;
        }
    }

    id txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    if ([txPower isKindOfClass:[NSNumber class]]) {
        adv[CBAdvertisementDataTxPowerLevelKey] = txPower;
    }

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
    [self cancelPendingL2capOpenForPeripheralId:peripheral.identifier];
    [self sendDisconnectForPeripheral:peripheral
                            timestamp:CFAbsoluteTimeGetCurrent()
                       isReconnecting:NO
                                error:error];
}

- (void)centralManager:(CBCentralManager *)central
 didDisconnectPeripheral:(CBPeripheral *)peripheral
              timestamp:(CFAbsoluteTime)timestamp
         isReconnecting:(BOOL)isReconnecting
                  error:(NSError *)error API_AVAILABLE(ios(17.0), macos(14.0)) {
    [self cancelPendingL2capOpenForPeripheralId:peripheral.identifier];
    [self sendDisconnectForPeripheral:peripheral
                            timestamp:timestamp
                       isReconnecting:isReconnecting
                                error:error];
}

- (void)centralManager:(CBCentralManager *)central
connectionEventDidOccur:(CBConnectionEvent)event
          forPeripheral:(CBPeripheral *)peripheral API_AVAILABLE(ios(13.0)) {
    if (!peripheral.identifier) {
        return;
    }
    [self sendMessage:@{
        @"type": @"connectionEvent",
        @"id": peripheral.identifier.UUIDString,
        @"event": @(event)
    }];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSMutableArray *servicesPayload = [NSMutableArray array];
    NSArray<CBService *> *services = peripheral.services ?: @[];
    // macOS CoreBluetooth may return ALL cached services even when a filtered
    // discoverServices: was requested.  iOS only returns the requested subset.
    // Mirror iOS behavior so the shim client sees the correct service list.
    NSSet<CBUUID *> *filter = self.pendingServiceFilters[peripheral.identifier];
    if (filter.count > 0) {
        NSMutableArray<CBService *> *filtered = [NSMutableArray array];
        for (CBService *svc in services) {
            if ([filter containsObject:svc.UUID]) {
                [filtered addObject:svc];
            }
        }
        services = filtered;
    }
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

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverIncludedServicesForService:(CBService *)service error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *serviceId = objc_getAssociatedObject(service, kCBSServiceIdKey);
    if (![serviceId isKindOfClass:[NSString class]]) {
        return;
    }
    NSMutableArray *includedPayload = [NSMutableArray array];
    NSArray<CBService *> *includedServices = service.includedServices ?: @[];
    [includedServices enumerateObjectsUsingBlock:^(CBService *includedService, NSUInteger idx, BOOL *stop) {
        NSString *includedServiceId = [self serviceIdForPeripheral:peripheral service:includedService index:idx];
        objc_setAssociatedObject(includedService, kCBSServiceIdKey, includedServiceId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.servicesById[includedServiceId] = includedService;
        [includedPayload addObject:@{
            @"id": includedServiceId,
            @"uuid": includedService.UUID.UUIDString ?: @"",
            @"primary": @(includedService.isPrimary)
        }];
    }];
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didDiscoverIncludedServices",
        @"id": peripheral.identifier.UUIDString,
        @"serviceId": serviceId,
        @"includedServices": includedPayload,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *characteristicId = objc_getAssociatedObject(characteristic, kCBSCharacteristicIdKey);
    if (![characteristicId isKindOfClass:[NSString class]]) {
        return;
    }
    NSMutableArray *descriptorsPayload = [NSMutableArray array];
    NSArray<CBDescriptor *> *descriptors = characteristic.descriptors ?: @[];
    [descriptors enumerateObjectsUsingBlock:^(CBDescriptor *descriptor, NSUInteger idx, BOOL *stop) {
        NSString *descriptorId = [self descriptorIdForCharacteristicId:characteristicId descriptor:descriptor index:idx];
        objc_setAssociatedObject(descriptor, kCBSDescriptorIdKey, descriptorId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.descriptorsById[descriptorId] = descriptor;
        [descriptorsPayload addObject:@{
            @"id": descriptorId,
            @"uuid": descriptor.UUID.UUIDString ?: @""
        }];
    }];
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didDiscoverDescriptors",
        @"id": peripheral.identifier.UUIDString,
        @"characteristicId": characteristicId,
        @"descriptors": descriptorsPayload,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didReadRSSI:(NSNumber *)RSSI error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didReadRSSI",
        @"id": peripheral.identifier.UUIDString,
        @"rssi": RSSI ?: @0,
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

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *descriptorId = objc_getAssociatedObject(descriptor, kCBSDescriptorIdKey);
    if (![descriptorId isKindOfClass:[NSString class]]) {
        return;
    }
    NSString *valueB64 = @"";
    id value = [self jsonSafeDescriptorValue:descriptor.value descriptorValueB64Out:&valueB64];
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didUpdateDescriptorValue",
        @"id": peripheral.identifier.UUIDString,
        @"descriptorId": descriptorId,
        @"value": value ?: [NSNull null],
        @"valueB64": valueB64,
        @"error": errStr
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
    if (!peripheral.identifier) {
        return;
    }
    NSString *descriptorId = objc_getAssociatedObject(descriptor, kCBSDescriptorIdKey);
    if (![descriptorId isKindOfClass:[NSString class]]) {
        return;
    }
    NSString *errStr = error ? [error localizedDescription] : @"";
    [self sendMessage:@{
        @"type": @"didWriteDescriptorValue",
        @"id": peripheral.identifier.UUIDString,
        @"descriptorId": descriptorId,
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
    [self cancelPendingL2capOpenForPeripheralId:peripheral.identifier];
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

- (void)peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray<CBService *> *)invalidatedServices {
    if (!peripheral.identifier) {
        return;
    }
    NSMutableArray *payload = [NSMutableArray array];
    for (CBService *service in invalidatedServices) {
        NSString *serviceId = objc_getAssociatedObject(service, kCBSServiceIdKey);
        if (!serviceId || ![serviceId isKindOfClass:[NSString class]]) {
            continue;
        }
        [payload addObject:serviceId];
    }
    [self sendMessage:@{
        @"type": @"didModifyServices",
        @"id": peripheral.identifier.UUIDString,
        @"serviceIds": payload
    }];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    if (!peripheral.identifier) {
        return;
    }
    [self sendMessage:@{
        @"type": @"didReadyToWriteWithoutResponse",
        @"id": peripheral.identifier.UUIDString
    }];
}

- (void)peripheralDidUpdateName:(CBPeripheral *)peripheral {
    if (!peripheral.identifier) {
        return;
    }
    [self sendMessage:@{
        @"type": @"didUpdateName",
        @"id": peripheral.identifier.UUIDString,
        @"name": peripheral.name ?: @""
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
        signal(SIGPIPE, SIG_IGN);
        NSLog(@"ImpossiBLE-Helper: starting");
        CBSHelper *helper = [[CBSHelper alloc] init];
        [helper start];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
