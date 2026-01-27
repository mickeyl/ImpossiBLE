#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

@class CBSService;
@class CBSCharacteristic;

@interface CBSPeripheral : NSObject
@property(nonatomic, readonly) NSUUID *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, weak) id<CBPeripheralDelegate> delegate;
@property(nonatomic, readonly) CBPeripheralState state;
@property(nonatomic, copy) NSArray *services;
- (instancetype)initWithIdentifier:(NSUUID *)identifier name:(NSString *)name;
- (void)cbs_updateName:(NSString *)name;
- (void)cbs_setState:(CBPeripheralState)state;
- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs;
- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs forService:(CBService *)service;
- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic;
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type;
- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic;
- (void)openL2CAPChannel:(CBL2CAPPSM)PSM;
- (NSInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)type;
- (BOOL)canSendWriteWithoutResponse;
@end

@interface CBSService : CBService
@property(nonatomic, copy) NSString *shimId;
- (void)cbs_setCharacteristics:(NSArray *)characteristics;
- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
                   primary:(BOOL)primary
                peripheral:(CBSPeripheral *)peripheral;
@end

@interface CBSCharacteristic : CBCharacteristic
@property(nonatomic, copy) NSString *shimId;
- (void)cbs_setValue:(NSData *)value;
- (void)cbs_setNotifying:(BOOL)notifying;
- (instancetype)initWithId:(NSString *)shimId
                      uuid:(CBUUID *)uuid
                properties:(CBCharacteristicProperties)properties
                   service:(CBSService *)service;
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
