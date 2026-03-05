#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

@class CBSService;
@class CBSCharacteristic;
@class CBSDescriptor;

@interface CBSPeripheral : CBPeripheral
@property(nonatomic, readonly) NSUUID *identifier;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, weak) id<CBPeripheralDelegate> delegate;
@property(nonatomic, readonly) CBPeripheralState state;
@property(nonatomic, retain) NSArray *services;
- (instancetype)initWithIdentifier:(NSUUID *)identifier name:(NSString *)name;
- (void)cbs_updateName:(NSString *)name;
- (void)cbs_setState:(CBPeripheralState)state;
- (void)readRSSI;
- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs;
- (void)discoverIncludedServices:(NSArray<CBUUID *> *)includedServiceUUIDs forService:(CBService *)service;
- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs forService:(CBService *)service;
- (void)discoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic;
- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic;
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type;
- (void)readValueForDescriptor:(CBDescriptor *)descriptor;
- (void)writeValue:(NSData *)data forDescriptor:(CBDescriptor *)descriptor;
- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic;
- (void)openL2CAPChannel:(CBL2CAPPSM)PSM;
- (NSInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type;
- (BOOL)canSendWriteWithoutResponse;
- (BOOL)ancsAuthorized;
@end

@interface CBSService : CBService
@property(nonatomic, copy) NSString *shimId;
- (void)cbs_setCharacteristics:(NSArray *)characteristics;
- (void)cbs_setIncludedServices:(NSArray *)includedServices;
- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
                   primary:(BOOL)primary
                peripheral:(CBSPeripheral *)peripheral;
@end

@interface CBSCharacteristic : CBCharacteristic
@property(nonatomic, copy) NSString *shimId;
- (void)cbs_setValue:(NSData *)value;
- (void)cbs_setNotifying:(BOOL)notifying;
- (void)cbs_setDescriptors:(NSArray *)descriptors;
- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
                properties:(CBCharacteristicProperties)properties
                   service:(CBSService *)service;
@end

@interface CBSDescriptor : CBDescriptor
@property(nonatomic, copy) NSString *shimId;
- (void)cbs_setValue:(id)value;
- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
            characteristic:(CBSCharacteristic *)characteristic;
@end

@interface CBSChannel : NSObject
@property(nonatomic, readonly) CBL2CAPPSM PSM;
@property(nonatomic, readonly) NSInputStream *inputStream;
@property(nonatomic, readonly) NSOutputStream *outputStream;
@property(nonatomic, readonly) CBPeer *peer;
@property(nonatomic, copy) NSString *shimId;
- (instancetype)initWithId:(NSString *)shimId
                       psm:(CBL2CAPPSM)psm
               inputStream:(NSInputStream *)inputStream
              outputStream:(NSOutputStream *)outputStream
                      peer:(CBPeer *)peer;
@end
