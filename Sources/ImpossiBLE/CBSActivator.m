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
static void *kCBSIsScanningKey = &kCBSIsScanningKey;
static void *kCBSScanServiceFilterKey = &kCBSScanServiceFilterKey;
static void *kCBSScanWireOptionsKey = &kCBSScanWireOptionsKey;
static void *kCBSCentralKeyKey = &kCBSCentralKeyKey;
static CBCentralManager *cbs_owner_central_for_peripheral(NSUUID *identifier);
static NSArray<CBSPeripheral *> *cbs_all_peripherals_for_uuid(NSUUID *uuid);
static uint64_t gNextCentralId = 1;

static CBCentralManager *gCentral;
static NSHashTable<CBCentralManager *> *gCentrals;
static NSMapTable<NSString *, CBCentralManager *> *gCentralByKey;
static NSMutableDictionary<NSUUID *, NSString *> *gPeripheralOwners;
static NSDictionary *gActiveScanPayload;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSUUID *, CBSPeripheral *> *> *gPeripheralsByCentral;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, CBSService *> *> *gServicesByCentral;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, CBSCharacteristic *> *> *gCharacteristicsByCentral;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, CBSDescriptor *> *> *gDescriptorsByCentral;
static NSMutableDictionary<NSUUID *, NSSet<NSString *> *> *gAdvertisedServices;
static NSMutableDictionary<NSString *, CBSChannel *> *gL2CAPChannels;
static NSMutableDictionary<NSString *, dispatch_source_t> *gL2CAPReadSources;
static NSMutableDictionary<NSString *, NSNumber *> *gL2CAPFds;

#pragma mark - State Change Notification

static void cbs_notify_all_centrals_state_changed(void) {
    NSArray *centrals = gCentrals.allObjects;
    for (CBCentralManager *central in centrals) {
        id delegate = central.delegate;
        if (delegate && [delegate respondsToSelector:@selector(centralManagerDidUpdateState:)]) {
            dispatch_queue_t q = objc_getAssociatedObject(central, kCBSDelegateQueueKey);
            if (!q) q = dispatch_get_main_queue();
            dispatch_async(q, ^{
                [delegate centralManagerDidUpdateState:central];
            });
        }
    }
}

#pragma mark - Callback Dispatch

static dispatch_queue_t cbs_callback_queue(void) {
    CBCentralManager *central = gCentral;
    dispatch_queue_t queue = objc_getAssociatedObject(central, kCBSDelegateQueueKey);
    return queue ?: dispatch_get_main_queue();
}

static dispatch_queue_t cbs_callback_queue_for_central(CBCentralManager *central) {
    dispatch_queue_t queue = objc_getAssociatedObject(central, kCBSDelegateQueueKey);
    return queue ?: dispatch_get_main_queue();
}

static dispatch_queue_t cbs_callback_queue_for_peripheral(CBSPeripheral *peripheral) {
    CBCentralManager *owner = cbs_owner_central_for_peripheral(peripheral.identifier);
    if (owner) {
        return cbs_callback_queue_for_central(owner);
    }
    return cbs_callback_queue();
}

static NSString *cbs_central_key(CBCentralManager *central) {
    NSString *key = objc_getAssociatedObject(central, kCBSCentralKeyKey);
    if (!key) {
        key = [NSString stringWithFormat:@"cbs_%llu", gNextCentralId++];
        objc_setAssociatedObject(central, kCBSCentralKeyKey, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return key;
}

static void cbs_cleanup_central_stores(NSString *key) {
    [gPeripheralsByCentral removeObjectForKey:key];
    [gServicesByCentral removeObjectForKey:key];
    [gCharacteristicsByCentral removeObjectForKey:key];
    [gDescriptorsByCentral removeObjectForKey:key];

    NSMutableArray<NSUUID *> *orphanedUUIDs = [NSMutableArray array];
    for (NSUUID *uuid in gPeripheralOwners) {
        if ([key isEqualToString:gPeripheralOwners[uuid]]) {
            [orphanedUUIDs addObject:uuid];
        }
    }
    [gPeripheralOwners removeObjectsForKeys:orphanedUUIDs];
}

static void cbs_register_central(CBCentralManager *central) {
    if (!central) {
        return;
    }
    if (!gCentrals) {
        gCentrals = [NSHashTable weakObjectsHashTable];
    }
    if (!gCentralByKey) {
        gCentralByKey = [NSMapTable strongToWeakObjectsMapTable];
    }
    NSString *key = cbs_central_key(central);
    [gCentrals addObject:central];
    [gCentralByKey setObject:central forKey:key];
}

static CBCentralManager *cbs_owner_central_for_peripheral(NSUUID *identifier) {
    if (!identifier) {
        return nil;
    }
    NSString *ownerKey = gPeripheralOwners[identifier];
    if (![ownerKey isKindOfClass:[NSString class]]) {
        return nil;
    }
    return [gCentralByKey objectForKey:ownerKey];
}

static NSMutableDictionary<NSUUID *, CBSPeripheral *> *cbs_peripheral_store_for_central_key(NSString *centralKey, BOOL create) {
    if (![centralKey isKindOfClass:[NSString class]] || centralKey.length == 0) {
        return nil;
    }
    if (!gPeripheralsByCentral && create) {
        gPeripheralsByCentral = [NSMutableDictionary dictionary];
    }
    NSMutableDictionary<NSUUID *, CBSPeripheral *> *store = gPeripheralsByCentral[centralKey];
    if (!store && create) {
        store = [NSMutableDictionary dictionary];
        gPeripheralsByCentral[centralKey] = store;
    }
    return store;
}

static NSMutableDictionary<NSUUID *, CBSPeripheral *> *cbs_peripheral_store_for_central(CBCentralManager *central, BOOL create) {
    return cbs_peripheral_store_for_central_key(cbs_central_key(central), create);
}

static CBSPeripheral *cbs_peripheral_for_central(CBCentralManager *central, NSUUID *uuid, NSString *name, BOOL create) {
    if (!central || !uuid) {
        return nil;
    }
    NSMutableDictionary<NSUUID *, CBSPeripheral *> *store = cbs_peripheral_store_for_central(central, create);
    CBSPeripheral *peripheral = store[uuid];
    if (!peripheral && create) {
        peripheral = [[CBSPeripheral alloc] initWithIdentifier:uuid name:(name ?: @"")];
        store[uuid] = peripheral;
        // Real CoreBluetooth shares a single CBPeripheral across CBCentralManagers.
        // Mirror that by copying discovered state from any existing shim peripheral.
        NSArray<CBSPeripheral *> *existing = cbs_all_peripherals_for_uuid(uuid);
        for (CBSPeripheral *donor in existing) {
            if (donor == peripheral) {
                continue;
            }
            if (donor.services.count > 0) {
                peripheral.services = donor.services;
            }
            if (donor.name.length > 0 && peripheral.name.length == 0) {
                [peripheral cbs_updateName:donor.name];
            }
            if (donor.state != CBPeripheralStateDisconnected) {
                [peripheral cbs_setState:donor.state];
            }
            if (peripheral.services.count > 0) {
                break;
            }
        }
    } else if (peripheral && [name isKindOfClass:[NSString class]] && name.length > 0) {
        [peripheral cbs_updateName:name];
    }
    return peripheral;
}

static CBSPeripheral *cbs_owner_peripheral_for_uuid(NSUUID *uuid) {
    CBCentralManager *owner = cbs_owner_central_for_peripheral(uuid);
    if (!owner) {
        return nil;
    }
    return cbs_peripheral_for_central(owner, uuid, nil, YES);
}

static NSArray<CBSPeripheral *> *cbs_all_peripherals_for_uuid(NSUUID *uuid) {
    if (!uuid || !gPeripheralsByCentral) {
        return @[];
    }
    NSMutableArray<CBSPeripheral *> *matches = [NSMutableArray array];
    for (NSMutableDictionary<NSUUID *, CBSPeripheral *> *store in gPeripheralsByCentral.allValues) {
        CBSPeripheral *peripheral = store[uuid];
        if (peripheral) {
            [matches addObject:peripheral];
        }
    }
    return matches;
}

static CBSPeripheral *cbs_any_peripheral_for_uuid(NSUUID *uuid) {
    NSArray<CBSPeripheral *> *matches = cbs_all_peripherals_for_uuid(uuid);
    return matches.count > 0 ? matches.firstObject : nil;
}

static NSString *cbs_owner_key_for_peripheral_uuid(NSUUID *uuid) {
    if (!uuid) {
        return nil;
    }
    NSString *ownerKey = gPeripheralOwners[uuid];
    if ([ownerKey isKindOfClass:[NSString class]] && ownerKey.length > 0) {
        return ownerKey;
    }
    return nil;
}

static NSMutableDictionary<NSString *, CBSService *> *cbs_service_store_for_owner_key(NSString *ownerKey, BOOL create) {
    if (![ownerKey isKindOfClass:[NSString class]] || ownerKey.length == 0) {
        return nil;
    }
    if (!gServicesByCentral && create) {
        gServicesByCentral = [NSMutableDictionary dictionary];
    }
    NSMutableDictionary<NSString *, CBSService *> *store = gServicesByCentral[ownerKey];
    if (!store && create) {
        store = [NSMutableDictionary dictionary];
        gServicesByCentral[ownerKey] = store;
    }
    return store;
}

static NSMutableDictionary<NSString *, CBSCharacteristic *> *cbs_characteristic_store_for_owner_key(NSString *ownerKey, BOOL create) {
    if (![ownerKey isKindOfClass:[NSString class]] || ownerKey.length == 0) {
        return nil;
    }
    if (!gCharacteristicsByCentral && create) {
        gCharacteristicsByCentral = [NSMutableDictionary dictionary];
    }
    NSMutableDictionary<NSString *, CBSCharacteristic *> *store = gCharacteristicsByCentral[ownerKey];
    if (!store && create) {
        store = [NSMutableDictionary dictionary];
        gCharacteristicsByCentral[ownerKey] = store;
    }
    return store;
}

static NSMutableDictionary<NSString *, CBSDescriptor *> *cbs_descriptor_store_for_owner_key(NSString *ownerKey, BOOL create) {
    if (![ownerKey isKindOfClass:[NSString class]] || ownerKey.length == 0) {
        return nil;
    }
    if (!gDescriptorsByCentral && create) {
        gDescriptorsByCentral = [NSMutableDictionary dictionary];
    }
    NSMutableDictionary<NSString *, CBSDescriptor *> *store = gDescriptorsByCentral[ownerKey];
    if (!store && create) {
        store = [NSMutableDictionary dictionary];
        gDescriptorsByCentral[ownerKey] = store;
    }
    return store;
}

static CBSService *cbs_find_service(NSUUID *uuid, NSString *serviceId) {
    if (!uuid || ![serviceId isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid);
    CBSService *service = cbs_service_store_for_owner_key(ownerKey, NO)[serviceId];
    if (service) {
        return service;
    }
    for (NSDictionary<NSString *, CBSService *> *store in gServicesByCentral.allValues) {
        CBSService *candidate = store[serviceId];
        if (!candidate) {
            continue;
        }
        NSUUID *candidateUUID = candidate.peripheral.identifier;
        if ([candidateUUID isKindOfClass:[NSUUID class]] && [candidateUUID isEqual:uuid]) {
            return candidate;
        }
    }
    return nil;
}

static CBSCharacteristic *cbs_find_characteristic(NSUUID *uuid, NSString *characteristicId) {
    if (!uuid || ![characteristicId isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid);
    CBSCharacteristic *characteristic = cbs_characteristic_store_for_owner_key(ownerKey, NO)[characteristicId];
    if (characteristic) {
        return characteristic;
    }
    for (NSDictionary<NSString *, CBSCharacteristic *> *store in gCharacteristicsByCentral.allValues) {
        CBSCharacteristic *candidate = store[characteristicId];
        if (!candidate) {
            continue;
        }
        NSUUID *candidateUUID = candidate.service.peripheral.identifier;
        if ([candidateUUID isKindOfClass:[NSUUID class]] && [candidateUUID isEqual:uuid]) {
            return candidate;
        }
    }
    return nil;
}

static CBSDescriptor *cbs_find_descriptor(NSUUID *uuid, NSString *descriptorId) {
    if (!uuid || ![descriptorId isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid);
    CBSDescriptor *descriptor = cbs_descriptor_store_for_owner_key(ownerKey, NO)[descriptorId];
    if (descriptor) {
        return descriptor;
    }
    for (NSDictionary<NSString *, CBSDescriptor *> *store in gDescriptorsByCentral.allValues) {
        CBSDescriptor *candidate = store[descriptorId];
        if (!candidate) {
            continue;
        }
        NSUUID *candidateUUID = candidate.characteristic.service.peripheral.identifier;
        if ([candidateUUID isKindOfClass:[NSUUID class]] && [candidateUUID isEqual:uuid]) {
            return candidate;
        }
    }
    return nil;
}

static BOOL cbs_is_scanning_for_central(CBCentralManager *central) {
    NSNumber *flag = objc_getAssociatedObject(central, kCBSIsScanningKey);
    return [flag respondsToSelector:@selector(boolValue)] ? flag.boolValue : NO;
}

static NSSet<NSString *> *cbs_scan_filter_for_central(CBCentralManager *central) {
    NSSet<NSString *> *filter = objc_getAssociatedObject(central, kCBSScanServiceFilterKey);
    return [filter isKindOfClass:[NSSet class]] ? filter : [NSSet set];
}

static NSDictionary *cbs_scan_wire_options_for_central(CBCentralManager *central) {
    NSDictionary *options = objc_getAssociatedObject(central, kCBSScanWireOptionsKey);
    return [options isKindOfClass:[NSDictionary class]] ? options : @{};
}

static NSError *cbs_error_from_message(NSString *errStr) {
    if (![errStr isKindOfClass:[NSString class]] || errStr.length == 0) {
        return nil;
    }
    return [NSError errorWithDomain:@"ImpossiBLE" code:1 userInfo:@{NSLocalizedDescriptionKey: errStr}];
}

static NSError *cbs_error_from_msg(NSDictionary *msg) {
    NSString *domain = msg[@"errorDomain"];
    NSNumber *code = msg[@"errorCode"];
    NSString *errStr = msg[@"error"];
    if ([domain isKindOfClass:[NSString class]] && [code isKindOfClass:[NSNumber class]]) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if ([errStr isKindOfClass:[NSString class]] && errStr.length > 0) {
            info[NSLocalizedDescriptionKey] = errStr;
        }
        return [NSError errorWithDomain:domain code:code.integerValue userInfo:info];
    }
    return cbs_error_from_message(errStr);
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

static NSSet<NSString *> *cbs_normalized_uuid_string_set(NSArray *uuids) {
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    if (![uuids isKindOfClass:[NSArray class]]) {
        return out;
    }
    for (id item in uuids) {
        NSString *uuidString = nil;
        if ([item isKindOfClass:[CBUUID class]]) {
            uuidString = ((CBUUID *)item).UUIDString;
        } else if ([item isKindOfClass:[NSString class]]) {
            uuidString = (NSString *)item;
        }
        if (uuidString.length > 0) {
            [out addObject:uuidString.uppercaseString];
        }
    }
    return out;
}

static NSSet<NSString *> *cbs_advertisement_service_set(NSDictionary *adv) {
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    NSDictionary *ad = [adv isKindOfClass:[NSDictionary class]] ? adv : @{};
    NSArray *keys = @[
        CBAdvertisementDataServiceUUIDsKey,
        CBAdvertisementDataOverflowServiceUUIDsKey,
        CBAdvertisementDataSolicitedServiceUUIDsKey
    ];
    for (NSString *key in keys) {
        NSSet<NSString *> *values = cbs_normalized_uuid_string_set(ad[key]);
        [out unionSet:values];
    }
    return out;
}

static NSUInteger cbs_active_scanning_central_count(void) {
    if (!gCentrals) {
        return 0;
    }
    NSUInteger count = 0;
    for (CBCentralManager *central in gCentrals.allObjects) {
        if (central && cbs_is_scanning_for_central(central)) {
            count += 1;
        }
    }
    return count;
}

static BOOL cbs_central_should_receive_discovery(CBCentralManager *central, CBSPeripheral *peripheral, NSDictionary *adv) {
    NSSet<NSString *> *wanted = cbs_scan_filter_for_central(central);
    if (wanted.count == 0) {
        return YES;
    }
    NSSet<NSString *> *advertised = cbs_advertisement_service_set(adv);
    if (advertised.count > 0 && [advertised intersectsSet:wanted]) {
        return YES;
    }
    NSSet<NSString *> *cachedAdvertised = gAdvertisedServices[peripheral.identifier];
    if (cachedAdvertised.count > 0 && [cachedAdvertised intersectsSet:wanted]) {
        return YES;
    }
    NSArray *services = peripheral.services;
    for (id service in services) {
        CBUUID *uuid = [service respondsToSelector:@selector(UUID)] ? [service UUID] : nil;
        NSString *uuidString = [uuid.UUIDString uppercaseString];
        if (uuidString.length > 0 && [wanted containsObject:uuidString]) {
            return YES;
        }
    }

    // CoreBluetooth can report discoveries even when advertisement payloads do not
    // contain service UUIDs we can inspect. In that ambiguous case, avoid starvation:
    // if this is the only active scanner, pass it through;
    // with multiple scanners, prefer broader filters (e.g. [FFF0, FFF1]) over narrow ones.
    BOOL hasInspectableServiceInfo =
        (advertised.count > 0) || (cachedAdvertised.count > 0) || (services.count > 0);
    if (!hasInspectableServiceInfo) {
        NSUInteger activeScanners = cbs_active_scanning_central_count();
        if (activeScanners <= 1) {
            return YES;
        }
        return wanted.count > 1;
    }

    return NO;
}

static NSDictionary *cbs_effective_scan_payload(void) {
    if (!gCentrals) {
        return nil;
    }
    BOOL hasScanningCentral = NO;
    BOOL hasUnfilteredScanner = NO;
    NSMutableSet<NSString *> *services = [NSMutableSet set];
    BOOL allowDuplicates = NO;
    NSMutableSet<NSString *> *solicited = [NSMutableSet set];
    NSMutableArray<NSString *> *activeScannerKeys = [NSMutableArray array];

    for (CBCentralManager *central in gCentrals.allObjects) {
        if (!central || !cbs_is_scanning_for_central(central)) {
            continue;
        }
        hasScanningCentral = YES;
        NSString *scannerKey = cbs_central_key(central);
        if (scannerKey.length > 0) {
            [activeScannerKeys addObject:scannerKey];
        }
        NSSet<NSString *> *filter = cbs_scan_filter_for_central(central);
        if (filter.count == 0) {
            hasUnfilteredScanner = YES;
        }
        [services unionSet:filter];
        NSDictionary *wireOptions = cbs_scan_wire_options_for_central(central);
        if ([wireOptions[CBCentralManagerScanOptionAllowDuplicatesKey] respondsToSelector:@selector(boolValue)] &&
            [wireOptions[CBCentralManagerScanOptionAllowDuplicatesKey] boolValue]) {
            allowDuplicates = YES;
        }
        NSArray *sol = wireOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey];
        if ([sol isKindOfClass:[NSArray class]]) {
            [solicited unionSet:cbs_normalized_uuid_string_set(sol)];
        }
    }

    if (!hasScanningCentral) {
        return nil;
    }
    NSArray<NSString *> *sortedScannerKeys = [activeScannerKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[CBCentralManagerScanOptionAllowDuplicatesKey] = @(allowDuplicates);
    if (solicited.count > 0) {
        NSArray *sortedSolicited = [[solicited allObjects] sortedArrayUsingSelector:@selector(compare:)];
        options[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = sortedSolicited;
        options[@"solicitedServiceUUIDs"] = sortedSolicited;
    }
    NSArray *sortedServices = hasUnfilteredScanner ? @[] : [[services allObjects] sortedArrayUsingSelector:@selector(compare:)];
    return @{
        @"type": @"scan",
        @"services": sortedServices,
        @"options": options,
        // Internal reconciliation metadata. Helper ignores unknown keys.
        @"_scannerKeys": sortedScannerKeys
    };
}

static void cbs_reconcile_scan_request(void) {
    NSDictionary *payload = cbs_effective_scan_payload();
    if (!payload) {
        if (gActiveScanPayload) {
            CBSConnectionSend(@{@"type": @"stopScan"});
            gActiveScanPayload = nil;
        }
        return;
    }
    if (gActiveScanPayload && [gActiveScanPayload isEqualToDictionary:payload]) {
        return;
    }
    gActiveScanPayload = payload;
    CBSConnectionSend(payload);
}

static BOOL cbs_peripheral_matches_service_filter(CBSPeripheral *peripheral, NSSet<NSString *> *wantedServices) {
    if (!peripheral || wantedServices.count == 0) {
        return YES;
    }

    NSArray *services = [peripheral services];
    for (id service in services) {
        CBUUID *uuid = [service respondsToSelector:@selector(UUID)] ? [service UUID] : nil;
        NSString *uuidString = [uuid.UUIDString uppercaseString];
        if (uuidString.length > 0 && [wantedServices containsObject:uuidString]) {
            return YES;
        }
    }

    NSSet<NSString *> *advertised = gAdvertisedServices[peripheral.identifier];
    if (advertised.count > 0) {
        for (NSString *uuidString in wantedServices) {
            if ([advertised containsObject:uuidString]) {
                return YES;
            }
        }
    }

    return NO;
}

static id cbs_decode_descriptor_value(NSDictionary *msg) {
    id valueB64 = msg[@"valueB64"];
    if ([valueB64 isKindOfClass:[NSString class]] && [valueB64 length] > 0) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:valueB64 options:0];
        if (data) {
            return data;
        }
    }
    id value = msg[@"value"];
    if (!value || value == [NSNull null]) {
        return nil;
    }
    return value;
}

#pragma mark - Message Handler

static NSDictionary *cbs_decode_advertisement(NSDictionary *wireAdv) {
    NSDictionary *raw = [wireAdv isKindOfClass:[NSDictionary class]] ? wireAdv : @{};
    NSMutableDictionary *decoded = [NSMutableDictionary dictionary];

    id localName = raw[CBAdvertisementDataLocalNameKey] ?: raw[@"localName"];
    if ([localName isKindOfClass:[NSString class]] && [localName length] > 0) {
        decoded[CBAdvertisementDataLocalNameKey] = localName;
    }

    id connectable = raw[CBAdvertisementDataIsConnectable];
    if ([connectable respondsToSelector:@selector(boolValue)]) {
        decoded[CBAdvertisementDataIsConnectable] = @([connectable boolValue]);
    }

    id serviceUUIDs = raw[CBAdvertisementDataServiceUUIDsKey];
    if ([serviceUUIDs isKindOfClass:[NSArray class]]) {
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        for (id item in (NSArray *)serviceUUIDs) {
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
            decoded[CBAdvertisementDataServiceUUIDsKey] = uuids;
        }
    }

    NSArray *(^decodeUUIDArray)(id) = ^NSArray *(id value) {
        if (![value isKindOfClass:[NSArray class]]) {
            return nil;
        }
        NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            if ([item isKindOfClass:[CBUUID class]]) {
                [uuids addObject:item];
            } else if ([item isKindOfClass:[NSString class]]) {
                CBUUID *uuid = [CBUUID UUIDWithString:item];
                if (uuid) {
                    [uuids addObject:uuid];
                }
            }
        }
        return uuids.count > 0 ? uuids : nil;
    };

    NSArray *overflowUUIDs = decodeUUIDArray(raw[CBAdvertisementDataOverflowServiceUUIDsKey]);
    if (overflowUUIDs) {
        decoded[CBAdvertisementDataOverflowServiceUUIDsKey] = overflowUUIDs;
    }

    NSArray *solicitedUUIDs = decodeUUIDArray(raw[CBAdvertisementDataSolicitedServiceUUIDsKey]);
    if (solicitedUUIDs) {
        decoded[CBAdvertisementDataSolicitedServiceUUIDsKey] = solicitedUUIDs;
    }

    id manufacturerData = raw[CBAdvertisementDataManufacturerDataKey];
    if ([manufacturerData isKindOfClass:[NSString class]]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:(NSString *)manufacturerData options:0];
        if (data) {
            decoded[CBAdvertisementDataManufacturerDataKey] = data;
        }
    } else if ([manufacturerData isKindOfClass:[NSData class]]) {
        decoded[CBAdvertisementDataManufacturerDataKey] = manufacturerData;
    }

    id serviceData = raw[CBAdvertisementDataServiceDataKey];
    if ([serviceData isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *decodedServiceData = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)serviceData) {
            NSString *uuidString = [key isKindOfClass:[NSString class]] ? (NSString *)key : nil;
            NSString *valueB64 = [serviceData[key] isKindOfClass:[NSString class]] ? serviceData[key] : nil;
            if (!uuidString || !valueB64) {
                continue;
            }
            CBUUID *uuid = [CBUUID UUIDWithString:uuidString];
            NSData *value = [[NSData alloc] initWithBase64EncodedString:valueB64 options:0];
            if (uuid && value) {
                decodedServiceData[uuid] = value;
            }
        }
        if (decodedServiceData.count > 0) {
            decoded[CBAdvertisementDataServiceDataKey] = decodedServiceData;
        }
    }

    id txPower = raw[CBAdvertisementDataTxPowerLevelKey];
    if ([txPower isKindOfClass:[NSNumber class]]) {
        decoded[CBAdvertisementDataTxPowerLevelKey] = txPower;
    }
    return decoded;
}

static NSDictionary *cbs_decode_scan_options(NSDictionary *wireOptions) {
    NSDictionary *raw = [wireOptions isKindOfClass:[NSDictionary class]] ? wireOptions : @{};
    NSMutableDictionary *decoded = [NSMutableDictionary dictionary];

    id allowDuplicates = raw[CBCentralManagerScanOptionAllowDuplicatesKey];
    if ([allowDuplicates respondsToSelector:@selector(boolValue)]) {
        decoded[CBCentralManagerScanOptionAllowDuplicatesKey] = @([allowDuplicates boolValue]);
    }

    id solicited = raw[CBCentralManagerScanOptionSolicitedServiceUUIDsKey];
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
            decoded[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = uuids;
        }
    }

    return decoded;
}

static void cbs_handle_message(NSDictionary *msg) {
    NSString *type = msg[@"type"];
    if (![type isKindOfClass:[NSString class]]) {
        return;
    }

    if ([type isEqualToString:@"didDiscover"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *name = [msg[@"name"] isKindOfClass:[NSString class]] ? msg[@"name"] : @"";
        NSNumber *rssi = msg[@"rssi"] ?: @0;
        NSDictionary *adv = cbs_decode_advertisement(msg[@"adv"]);
        NSString *advName = adv[CBAdvertisementDataLocalNameKey];
        if (name.length == 0 && [advName isKindOfClass:[NSString class]]) {
            name = advName;
        }
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        if (!uuid) {
            return;
        }
        if (!gAdvertisedServices) {
            gAdvertisedServices = [NSMutableDictionary dictionary];
        }
        NSSet<NSString *> *serviceSet = cbs_advertisement_service_set(adv);
        if (serviceSet.count > 0) {
            gAdvertisedServices[uuid] = serviceSet;
        }

        NSArray<CBCentralManager *> *centrals = gCentrals ? gCentrals.allObjects : @[];
        BOOL delivered = NO;
        for (CBCentralManager *central in centrals) {
            if (!central || !cbs_is_scanning_for_central(central)) {
                continue;
            }
            CBSPeripheral *peripheral = cbs_peripheral_for_central(central, uuid, name, YES);
            if (!peripheral) {
                continue;
            }
            if (!cbs_central_should_receive_discovery(central, peripheral, adv)) {
                continue;
            }
            id<CBCentralManagerDelegate> delegate = central.delegate;
            if (!delegate || ![delegate respondsToSelector:@selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:)]) {
                continue;
            }
            CBPeripheral *cbPeripheral = (CBPeripheral *)peripheral;
            dispatch_queue_t queue = cbs_callback_queue_for_central(central);
            dispatch_async(queue, ^{
                [delegate centralManager:central
                   didDiscoverPeripheral:cbPeripheral
                        advertisementData:adv
                                     RSSI:rssi];
            });
            delivered = YES;
        }
        if (!delivered) {
            // Nobody actively scanning matched this discovery.
        }
        return;
    }

    if ([type isEqualToString:@"didRestoreState"]) {
        NSArray *peripheralIds = msg[@"peripheralIds"];
        NSArray *scanServices = msg[@"scanServices"];
        NSDictionary *scanOptions = msg[@"scanOptions"];

        CBCentralManager *central = nil;
        if ([peripheralIds isKindOfClass:[NSArray class]]) {
            for (id item in peripheralIds) {
                if (![item isKindOfClass:[NSString class]]) {
                    continue;
                }
                NSUUID *peripheralUUID = [[NSUUID alloc] initWithUUIDString:(NSString *)item];
                if (!peripheralUUID) {
                    continue;
                }
                central = cbs_owner_central_for_peripheral(peripheralUUID);
                if (central) {
                    break;
                }
            }
        }
        if (!central) {
            central = gCentral;
        }
        id<CBCentralManagerDelegate> delegate = central.delegate;
        if (!central || !delegate) {
            return;
        }
        if (![delegate respondsToSelector:@selector(centralManager:willRestoreState:)]) {
            return;
        }

        NSMutableArray *restoredPeripherals = [NSMutableArray array];
        if ([peripheralIds isKindOfClass:[NSArray class]]) {
            for (id item in peripheralIds) {
                if (![item isKindOfClass:[NSString class]]) {
                    continue;
                }
                NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:(NSString *)item];
                CBSPeripheral *peripheral = uuid ? cbs_peripheral_for_central(central, uuid, nil, YES) : nil;
                if (peripheral) {
                    [restoredPeripherals addObject:(CBPeripheral *)peripheral];
                }
            }
        }

        NSMutableArray *decodedServices = [NSMutableArray array];
        if ([scanServices isKindOfClass:[NSArray class]]) {
            for (id item in scanServices) {
                if ([item isKindOfClass:[CBUUID class]]) {
                    [decodedServices addObject:item];
                } else if ([item isKindOfClass:[NSString class]]) {
                    CBUUID *uuid = [CBUUID UUIDWithString:item];
                    if (uuid) {
                        [decodedServices addObject:uuid];
                    }
                }
            }
        }

        NSMutableDictionary *restoreState = [NSMutableDictionary dictionary];
        if (restoredPeripherals.count > 0) {
            restoreState[CBCentralManagerRestoredStatePeripheralsKey] = restoredPeripherals;
        }
        if (decodedServices.count > 0) {
            restoreState[CBCentralManagerRestoredStateScanServicesKey] = decodedServices;
        }
        NSDictionary *decodedOptions = cbs_decode_scan_options(scanOptions);
        if (decodedOptions.count > 0) {
            restoreState[CBCentralManagerRestoredStateScanOptionsKey] = decodedOptions;
        }

        dispatch_queue_t queue = cbs_callback_queue_for_central(central);
        dispatch_async(queue, ^{
            [delegate centralManager:central willRestoreState:restoreState];
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
        CBCentralManager *central = cbs_owner_central_for_peripheral(uuid) ?: gCentral;
        id<CBCentralManagerDelegate> delegate = central.delegate;
        if (!central || !delegate) {
            return;
        }
        CBSPeripheral *peripheral = cbs_peripheral_for_central(central, uuid, nil, YES);
        if (!peripheral) {
            return;
        }
        CBPeripheralState newState = [type isEqualToString:@"didConnect"] ? CBPeripheralStateConnected : CBPeripheralStateDisconnected;
        for (CBSPeripheral *p in cbs_all_peripherals_for_uuid(uuid)) {
            [p cbs_setState:newState];
        }
        dispatch_queue_t queue = cbs_callback_queue_for_central(central);
        CBPeripheral *cbPeripheral = (CBPeripheral *)peripheral;
        NSError *err = cbs_error_from_message(msg[@"error"]);
        NSNumber *timestampNum = msg[@"timestamp"];
        NSNumber *isReconnectingNum = msg[@"isReconnecting"];
        CFAbsoluteTime timestamp = [timestampNum respondsToSelector:@selector(doubleValue)] ? timestampNum.doubleValue : CFAbsoluteTimeGetCurrent();
        BOOL isReconnecting = [isReconnectingNum respondsToSelector:@selector(boolValue)] ? isReconnectingNum.boolValue : NO;
        dispatch_async(queue, ^{
            if ([type isEqualToString:@"didConnect"] &&
                [delegate respondsToSelector:@selector(centralManager:didConnectPeripheral:)]) {
                [delegate centralManager:central didConnectPeripheral:cbPeripheral];
            } else if ([type isEqualToString:@"didFailConnect"] &&
                       [delegate respondsToSelector:@selector(centralManager:didFailToConnectPeripheral:error:)]) {
                [delegate centralManager:central didFailToConnectPeripheral:cbPeripheral error:err];
                [gPeripheralOwners removeObjectForKey:uuid];
            } else if ([type isEqualToString:@"didDisconnect"] &&
                       [delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:timestamp:isReconnecting:error:)]) {
                [delegate centralManager:central
                   didDisconnectPeripheral:cbPeripheral
                                timestamp:timestamp
                           isReconnecting:isReconnecting
                                    error:err];
                [gPeripheralOwners removeObjectForKey:uuid];
            } else if ([type isEqualToString:@"didDisconnect"] &&
                       [delegate respondsToSelector:@selector(centralManager:didDisconnectPeripheral:error:)]) {
                [delegate centralManager:central didDisconnectPeripheral:cbPeripheral error:err];
                [gPeripheralOwners removeObjectForKey:uuid];
            }
        });
        return;
    }

    if ([type isEqualToString:@"connectionEvent"]) {
        NSString *uuidStr = msg[@"id"];
        NSNumber *eventNum = msg[@"event"] ?: @0;
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBCentralManager *central = cbs_owner_central_for_peripheral(uuid) ?: gCentral;
        id<CBCentralManagerDelegate> delegate = central.delegate;
        if (!central || !delegate) {
            return;
        }
        CBSPeripheral *peripheral = cbs_peripheral_for_central(central, uuid, nil, YES);
        if (!peripheral) {
            return;
        }
        if (![delegate respondsToSelector:@selector(centralManager:connectionEventDidOccur:forPeripheral:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_central(central);
        CBPeripheral *cbPeripheral = (CBPeripheral *)peripheral;
        CBConnectionEvent event = (CBConnectionEvent)eventNum.integerValue;
        dispatch_async(queue, ^{
            [delegate centralManager:central connectionEventDidOccur:event forPeripheral:cbPeripheral];
        });
        return;
    }

    if ([type isEqualToString:@"didUpdateName"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *name = [msg[@"name"] isKindOfClass:[NSString class]] ? msg[@"name"] : @"";
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        for (CBSPeripheral *peripheral in cbs_all_peripherals_for_uuid(uuid)) {
            [peripheral cbs_updateName:name];
            id<CBPeripheralDelegate> delegate = peripheral.delegate;
            if (!delegate || ![delegate respondsToSelector:@selector(peripheralDidUpdateName:)]) {
                continue;
            }
            dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
            dispatch_async(queue, ^{
                [delegate peripheralDidUpdateName:(CBPeripheral *)peripheral];
            });
        }
        return;
    }

    if ([type isEqualToString:@"didReadRSSI"]) {
        NSString *uuidStr = msg[@"id"];
        NSNumber *rssi = msg[@"rssi"] ?: @0;
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        if (!peripheral) {
            return;
        }
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didReadRSSI:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didReadRSSI:rssi error:err];
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
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        if (!peripheral) {
            return;
        }
        NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid) ?: cbs_central_key(gCentral);
        NSMutableDictionary<NSString *, CBSService *> *serviceStore = cbs_service_store_for_owner_key(ownerKey, YES);
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
            serviceStore[svcId] = service;
            [svcList addObject:service];
        }
        peripheral.services = svcList;
        for (CBSPeripheral *p in cbs_all_peripherals_for_uuid(uuid)) {
            if (p != peripheral) {
                p.services = svcList;
            }
        }
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didDiscoverServices:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didDiscoverServices:err];
        });
        return;
    }

    if ([type isEqualToString:@"didDiscoverIncludedServices"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *serviceId = msg[@"serviceId"];
        NSArray *includedServices = msg[@"includedServices"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] ||
            ![serviceId isKindOfClass:[NSString class]] ||
            ![includedServices isKindOfClass:[NSArray class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSService *service = cbs_find_service(uuid, serviceId);
        if (!peripheral || !service) {
            return;
        }
        NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid) ?: cbs_central_key(gCentral);
        NSMutableDictionary<NSString *, CBSService *> *serviceStore = cbs_service_store_for_owner_key(ownerKey, YES);
        NSMutableArray *includedList = [NSMutableArray array];
        for (NSDictionary *svc in includedServices) {
            if (![svc isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *incId = svc[@"id"];
            NSString *incUuid = svc[@"uuid"];
            NSNumber *primary = svc[@"primary"] ?: @0;
            if (![incId isKindOfClass:[NSString class]] || ![incUuid isKindOfClass:[NSString class]]) {
                continue;
            }
            CBUUID *uuidObj = [CBUUID UUIDWithString:incUuid];
            CBSService *included = [[CBSService alloc] initWithId:incId uuid:uuidObj primary:primary.boolValue peripheral:peripheral];
            serviceStore[incId] = included;
            [includedList addObject:included];
        }
        [service cbs_setIncludedServices:includedList];
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didDiscoverIncludedServicesForService:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didDiscoverIncludedServicesForService:(CBService *)service error:err];
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
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSService *service = cbs_find_service(uuid, serviceId);
        if (!peripheral || !service) {
            return;
        }
        NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid) ?: cbs_central_key(gCentral);
        NSMutableDictionary<NSString *, CBSCharacteristic *> *characteristicStore = cbs_characteristic_store_for_owner_key(ownerKey, YES);
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
            characteristicStore[chId] = chr;
            [chrList addObject:chr];
        }
        [service cbs_setCharacteristics:chrList];
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didDiscoverCharacteristicsForService:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didDiscoverDescriptors"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *characteristicId = msg[@"characteristicId"];
        NSArray *descriptors = msg[@"descriptors"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] ||
            ![characteristicId isKindOfClass:[NSString class]] ||
            ![descriptors isKindOfClass:[NSArray class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSCharacteristic *characteristic = cbs_find_characteristic(uuid, characteristicId);
        if (!peripheral || !characteristic) {
            return;
        }
        NSString *ownerKey = cbs_owner_key_for_peripheral_uuid(uuid) ?: cbs_central_key(gCentral);
        NSMutableDictionary<NSString *, CBSDescriptor *> *descriptorStore = cbs_descriptor_store_for_owner_key(ownerKey, YES);
        NSMutableArray *descriptorList = [NSMutableArray array];
        for (NSDictionary *desc in descriptors) {
            if (![desc isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *descId = desc[@"id"];
            NSString *descUuid = desc[@"uuid"];
            if (![descId isKindOfClass:[NSString class]] || ![descUuid isKindOfClass:[NSString class]]) {
                continue;
            }
            CBUUID *uuidObj = [CBUUID UUIDWithString:descUuid];
            CBSDescriptor *descriptor = [[CBSDescriptor alloc] initWithId:descId uuid:uuidObj characteristic:characteristic];
            descriptorStore[descId] = descriptor;
            [descriptorList addObject:descriptor];
        }
        [characteristic cbs_setDescriptors:descriptorList];
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didDiscoverDescriptorsForCharacteristic:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        NSError *err = cbs_error_from_message(errStr);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didUpdateValue"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *chId = msg[@"characteristicId"];
        NSString *valueB64 = msg[@"value"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![chId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSCharacteristic *chr = cbs_find_characteristic(uuid, chId);
        if (!peripheral || !chr) {
            return;
        }
        NSData *decodedValue = nil;
        if ([valueB64 isKindOfClass:[NSString class]] && valueB64.length > 0) {
            decodedValue = [[NSData alloc] initWithBase64EncodedString:valueB64 options:0];
        }
        NSError *err = cbs_error_from_msg(msg);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didUpdateValueForCharacteristic:error:)]) {
            [chr cbs_setValue:decodedValue];
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [chr cbs_setValue:decodedValue];
            [delegate peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)chr error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didWriteValue"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *chId = msg[@"characteristicId"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![chId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSCharacteristic *chr = cbs_find_characteristic(uuid, chId);
        if (!peripheral || !chr) {
            return;
        }
        NSError *err = cbs_error_from_msg(msg);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didWriteValueForCharacteristic:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)chr error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didUpdateDescriptorValue"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *descriptorId = msg[@"descriptorId"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![descriptorId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSDescriptor *descriptor = cbs_find_descriptor(uuid, descriptorId);
        if (!peripheral || !descriptor) {
            return;
        }
        id decodedValue = cbs_decode_descriptor_value(msg);
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didUpdateValueForDescriptor:error:)]) {
            [descriptor cbs_setValue:decodedValue];
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [descriptor cbs_setValue:decodedValue];
            [delegate peripheral:(CBPeripheral *)peripheral didUpdateValueForDescriptor:(CBDescriptor *)descriptor error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didWriteDescriptorValue"]) {
        NSString *uuidStr = msg[@"id"];
        NSString *descriptorId = msg[@"descriptorId"];
        NSString *errStr = msg[@"error"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![descriptorId isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSDescriptor *descriptor = cbs_find_descriptor(uuid, descriptorId);
        if (!peripheral || !descriptor) {
            return;
        }
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didWriteValueForDescriptor:error:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didWriteValueForDescriptor:(CBDescriptor *)descriptor error:err];
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
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        CBSCharacteristic *chr = cbs_find_characteristic(uuid, chId);
        if (!peripheral || !chr) {
            return;
        }
        BOOL notifying = enabled.boolValue;
        NSError *err = cbs_error_from_message(errStr);
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didUpdateNotificationStateForCharacteristic:error:)]) {
            [chr cbs_setNotifying:notifying];
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [chr cbs_setNotifying:notifying];
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
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
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
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        CBL2CAPChannel *cbChannel = (CBL2CAPChannel *)channel;
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didOpenL2CAPChannel:cbChannel error:err];
        });
        return;
    }

    if ([type isEqualToString:@"didModifyServices"]) {
        NSString *uuidStr = msg[@"id"];
        NSArray *serviceIds = msg[@"serviceIds"];
        if (![uuidStr isKindOfClass:[NSString class]] || ![serviceIds isKindOfClass:[NSArray class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        if (!peripheral) {
            return;
        }
        NSMutableArray *services = [NSMutableArray array];
        for (id serviceId in serviceIds) {
            if (![serviceId isKindOfClass:[NSString class]]) {
                continue;
            }
            CBSService *service = cbs_find_service(uuid, (NSString *)serviceId);
            if (service) {
                [services addObject:service];
            }
        }
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheral:didModifyServices:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [delegate peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray<CBService *> *)services];
        });
        return;
    }

    if ([type isEqualToString:@"didReadyToWriteWithoutResponse"]) {
        NSString *uuidStr = msg[@"id"];
        if (![uuidStr isKindOfClass:[NSString class]]) {
            return;
        }
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidStr];
        CBSPeripheral *peripheral = cbs_owner_peripheral_for_uuid(uuid);
        if (!peripheral) {
            return;
        }
        id<CBPeripheralDelegate> delegate = peripheral.delegate;
        if (!delegate || ![delegate respondsToSelector:@selector(peripheralIsReadyToSendWriteWithoutResponse:)]) {
            return;
        }
        dispatch_queue_t queue = cbs_callback_queue_for_peripheral(peripheral);
        dispatch_async(queue, ^{
            [delegate peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral];
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

static NSDictionary *cbs_scan_wire_options(NSDictionary *options) {
    NSDictionary *scanOptions = [options isKindOfClass:[NSDictionary class]] ? options : @{};
    NSMutableDictionary *wire = [NSMutableDictionary dictionary];

    id allowDuplicates = scanOptions[CBCentralManagerScanOptionAllowDuplicatesKey];
    if ([allowDuplicates respondsToSelector:@selector(boolValue)]) {
        BOOL allow = [allowDuplicates boolValue];
        wire[CBCentralManagerScanOptionAllowDuplicatesKey] = @(allow);
    } else {
        wire[CBCentralManagerScanOptionAllowDuplicatesKey] = @NO;
    }

    id solicited = scanOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey];
    if ([solicited isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *solicitedStrings = [NSMutableArray array];
        for (id item in (NSArray *)solicited) {
            if ([item isKindOfClass:[CBUUID class]]) {
                NSString *uuidString = ((CBUUID *)item).UUIDString;
                if (uuidString.length > 0) {
                    [solicitedStrings addObject:uuidString];
                }
            } else if ([item isKindOfClass:[NSString class]]) {
                [solicitedStrings addObject:item];
            }
        }
        if (solicitedStrings.count > 0) {
            wire[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = solicitedStrings;
            wire[@"solicitedServiceUUIDs"] = solicitedStrings;
        }
    }
    return wire;
}

static NSDictionary *cbs_connection_event_wire_options(NSDictionary *options) {
    NSDictionary *eventOptions = [options isKindOfClass:[NSDictionary class]] ? options : @{};
    NSMutableDictionary *wire = [NSMutableDictionary dictionary];
    for (id key in eventOptions) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        id value = eventOptions[key];
        if ([value isKindOfClass:[NSArray class]]) {
            NSMutableArray *serialized = [NSMutableArray array];
            for (id item in (NSArray *)value) {
                if ([item isKindOfClass:[CBUUID class]]) {
                    NSString *uuidString = ((CBUUID *)item).UUIDString;
                    if (uuidString.length > 0) {
                        [serialized addObject:uuidString];
                    }
                } else if ([item isKindOfClass:[NSUUID class]]) {
                    [serialized addObject:((NSUUID *)item).UUIDString ?: @""];
                } else if ([item isKindOfClass:[NSString class]] || [item isKindOfClass:[NSNumber class]]) {
                    [serialized addObject:item];
                }
            }
            wire[key] = serialized;
        } else if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
            wire[key] = value;
        }
    }
    return wire;
}

static void cbs_post_init(id obj, id delegate, dispatch_queue_t queue) {
    dispatch_queue_t q = queue ?: dispatch_get_main_queue();
    objc_setAssociatedObject(obj, kCBSDelegateQueueKey, q, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, kCBSIsScanningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, kCBSScanServiceFilterKey, [NSSet set], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, kCBSScanWireOptionsKey, @{}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gCentral = obj;
    cbs_register_central((CBCentralManager *)obj);
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

static id (*orig_init_plain)(id, SEL);
static id cbs_init_plain(id self, SEL _cmd) {
    id obj = orig_init_plain(self, _cmd);
    cbs_post_init(obj, nil, nil);
    return obj;
}

static CBManagerState (*orig_state)(id, SEL);
static CBManagerState cbs_state(id self, SEL _cmd) {
    return CBSConnectionIsConnected() ? CBManagerStatePoweredOn : CBManagerStatePoweredOff;
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
    cbs_register_central((CBCentralManager *)self);
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
    CBCentralManager *central = (CBCentralManager *)self;
    gCentral = central;
    cbs_register_central(central);
    NSArray<NSString *> *uuids = services ? cbs_uuid_strings(services) : @[];
    NSDictionary *wireOptions = cbs_scan_wire_options(options);
    NSSet<NSString *> *filterSet = cbs_normalized_uuid_string_set(uuids);
    objc_setAssociatedObject(central, kCBSIsScanningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(central, kCBSScanServiceFilterKey, filterSet ?: [NSSet set], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(central, kCBSScanWireOptionsKey, wireOptions ?: @{}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cbs_reconcile_scan_request();
}

static void (*orig_stop)(id, SEL);
static void cbs_stop(id self, SEL _cmd) {
    CBCentralManager *central = (CBCentralManager *)self;
    gCentral = central;
    objc_setAssociatedObject(central, kCBSIsScanningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cbs_reconcile_scan_request();
}

static void (*orig_connect)(id, SEL, id, NSDictionary *);
static void cbs_connect_peripheral(id self, SEL _cmd, id peripheral, NSDictionary *options) {
    CBCentralManager *central = (CBCentralManager *)self;
    gCentral = central;
    id ident = [peripheral respondsToSelector:@selector(identifier)] ? [peripheral identifier] : nil;
    NSUUID *uuid = [ident isKindOfClass:[NSUUID class]] ? ident : nil;
    if (uuid) {
        if (!gPeripheralOwners) {
            gPeripheralOwners = [NSMutableDictionary dictionary];
        }
        gPeripheralOwners[uuid] = cbs_central_key(central);
        CBSConnectionSend(@{@"type": @"connect", @"id": uuid.UUIDString, @"options": options ?: @{}});
    }
}

static void (*orig_cancel)(id, SEL, id);
static void cbs_cancel(id self, SEL _cmd, id peripheral) {
    CBCentralManager *central = (CBCentralManager *)self;
    gCentral = central;
    id ident = [peripheral respondsToSelector:@selector(identifier)] ? [peripheral identifier] : nil;
    NSUUID *uuid = [ident isKindOfClass:[NSUUID class]] ? ident : nil;
    if (uuid) {
        if (!gPeripheralOwners) {
            gPeripheralOwners = [NSMutableDictionary dictionary];
        }
        CBCentralManager *existingOwner = cbs_owner_central_for_peripheral(uuid);
        if (!existingOwner || existingOwner == central) {
            gPeripheralOwners[uuid] = cbs_central_key(central);
        }
        CBSConnectionSend(@{@"type": @"cancel", @"id": uuid.UUIDString});
    }
}

static BOOL (*orig_is_scanning)(id, SEL);
static BOOL cbs_is_scanning(id self, SEL _cmd) {
    return cbs_is_scanning_for_central((CBCentralManager *)self);
}

static void (*orig_dealloc)(id, SEL);
static void cbs_dealloc(id self, SEL _cmd) {
    NSString *key = objc_getAssociatedObject(self, kCBSCentralKeyKey);
    if (key) {
        cbs_cleanup_central_stores(key);
        [gCentralByKey removeObjectForKey:key];
    }
    if (gCentral == self) {
        gCentral = nil;
    }
    if (orig_dealloc) {
        orig_dealloc(self, _cmd);
    }
}

static void (*orig_register_for_connection_events)(id, SEL, NSDictionary *);
static void cbs_register_for_connection_events(id self, SEL _cmd, NSDictionary *options) {
    gCentral = self;
    NSDictionary *wireOptions = cbs_connection_event_wire_options(options);
    CBSConnectionSend(@{
        @"type": @"registerForConnectionEvents",
        @"options": wireOptions
    });
}

static NSArray *(*orig_retrieve_connected)(id, SEL, NSArray *);
static NSArray *cbs_retrieve_connected(id self, SEL _cmd, NSArray *services) {
    CBCentralManager *central = (CBCentralManager *)self;
    gCentral = central;
    NSSet<NSString *> *wantedServices = cbs_normalized_uuid_string_set(services);
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary<NSUUID *, CBSPeripheral *> *requestStore = cbs_peripheral_store_for_central(central, YES);
    NSMutableSet<NSUUID *> *seen = [NSMutableSet set];
    for (NSDictionary<NSUUID *, CBSPeripheral *> *store in gPeripheralsByCentral.allValues) {
        for (CBSPeripheral *source in store.allValues) {
            if ([source state] != CBPeripheralStateConnected) {
                continue;
            }
            NSUUID *uuid = source.identifier;
            if (!uuid || [seen containsObject:uuid]) {
                continue;
            }
            if (!cbs_peripheral_matches_service_filter(source, wantedServices)) {
                continue;
            }
            CBSPeripheral *target = requestStore[uuid];
            if (!target) {
                target = [[CBSPeripheral alloc] initWithIdentifier:uuid name:source.name ?: @""];
                requestStore[uuid] = target;
            } else if (source.name.length > 0) {
                [target cbs_updateName:source.name];
            }
            [target cbs_setState:CBPeripheralStateConnected];
            target.services = source.services ?: @[];
            [matches addObject:(CBPeripheral *)target];
            [seen addObject:uuid];
        }
    }
    return matches;
}

static NSArray *(*orig_retrieve_peripherals)(id, SEL, NSArray *);
static NSArray *cbs_retrieve_peripherals(id self, SEL _cmd, NSArray *identifiers) {
    CBCentralManager *central = (CBCentralManager *)self;
    gCentral = central;
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary<NSUUID *, CBSPeripheral *> *store = cbs_peripheral_store_for_central(central, YES);
    if ([identifiers isKindOfClass:[NSArray class]]) {
        for (id item in identifiers) {
            NSUUID *uuid = [item isKindOfClass:[NSUUID class]] ? (NSUUID *)item : nil;
            if (!uuid) {
                continue;
            }
            CBSPeripheral *peripheral = store[uuid];
            if (!peripheral) {
                CBSPeripheral *source = cbs_any_peripheral_for_uuid(uuid);
                if (source) {
                    peripheral = [[CBSPeripheral alloc] initWithIdentifier:uuid name:source.name ?: @""];
                    [peripheral cbs_setState:source.state];
                    peripheral.services = source.services ?: @[];
                    store[uuid] = peripheral;
                }
            }
            if (peripheral) {
                [matches addObject:(CBPeripheral *)peripheral];
            }
        }
    }
    return matches;
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

    CBSConnectionSetStateHandler(^(BOOL connected) {
        cbs_notify_all_centrals_state_changed();
    });

    CBSConnectionOpen();

    cbs_swizzle(cls, @selector(initWithDelegate:queue:options:), (IMP)cbs_init, (IMP *)&orig_init);
    cbs_swizzle(cls, @selector(initWithDelegate:queue:), (IMP)cbs_init_noopts, (IMP *)&orig_init_noopts);
    cbs_swizzle(cls, @selector(init), (IMP)cbs_init_plain, (IMP *)&orig_init_plain);
    cbs_swizzle(cls, @selector(state), (IMP)cbs_state, (IMP *)&orig_state);
    cbs_swizzle(cls, @selector(authorization), (IMP)cbs_authorization, (IMP *)&orig_authorization);
    cbs_swizzle_class(cls, @selector(authorization), (IMP)cbs_class_authorization, (IMP *)&orig_class_authorization);
    cbs_swizzle_class(cls, @selector(supportsFeatures:), (IMP)cbs_supports_features, (IMP *)&orig_supports_features);
    cbs_swizzle(cls, @selector(setDelegate:), (IMP)cbs_setDelegate, (IMP *)&orig_setDelegate);
    cbs_swizzle(cls, @selector(scanForPeripheralsWithServices:options:), (IMP)cbs_scan, (IMP *)&orig_scan);
    cbs_swizzle(cls, @selector(stopScan), (IMP)cbs_stop, (IMP *)&orig_stop);
    cbs_swizzle(cls, @selector(isScanning), (IMP)cbs_is_scanning, (IMP *)&orig_is_scanning);
    cbs_swizzle(cls, @selector(connectPeripheral:options:), (IMP)cbs_connect_peripheral, (IMP *)&orig_connect);
    cbs_swizzle(cls, @selector(cancelPeripheralConnection:), (IMP)cbs_cancel, (IMP *)&orig_cancel);
    cbs_swizzle(cls, @selector(registerForConnectionEventsWithOptions:), (IMP)cbs_register_for_connection_events, (IMP *)&orig_register_for_connection_events);
    cbs_swizzle(cls, @selector(retrieveConnectedPeripheralsWithServices:), (IMP)cbs_retrieve_connected, (IMP *)&orig_retrieve_connected);
    cbs_swizzle(cls, @selector(retrievePeripheralsWithIdentifiers:), (IMP)cbs_retrieve_peripherals, (IMP *)&orig_retrieve_peripherals);
    cbs_swizzle(cls, NSSelectorFromString(@"dealloc"), (IMP)cbs_dealloc, (IMP *)&orig_dealloc);

    Class mgr = NSClassFromString(@"CBManager");
    if (mgr) {
        cbs_swizzle(mgr, @selector(authorization), (IMP)cbs_authorization, NULL);
        cbs_swizzle_class(mgr, @selector(authorization), (IMP)cbs_class_authorization, NULL);
    }

    NSLog(@"ImpossiBLE: swizzles installed");
}

@end

#endif
