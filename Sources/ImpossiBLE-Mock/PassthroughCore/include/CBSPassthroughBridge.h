#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The CoreBluetooth <-> wire-protocol translation layer for Passthrough mode.
///
/// This is the former impossible-helper daemon minus its socket server: it
/// consumes decoded protocol messages and emits reply messages through
/// `messageHandler`, leaving transport ownership to whoever hosts it (the mock
/// app's socket server, or the capture workflow talking to it in process).
@interface CBSPassthroughBridge : NSObject

/// Outgoing protocol messages, invoked on a private serial queue.
@property (nonatomic, copy, nullable) void (^messageHandler)(NSDictionary<NSString *, id> *message);

/// Real-device communication activity (GATT/L2CAP operations only), invoked on
/// a private serial queue. Replaces the daemon's activity snapshot file.
@property (nonatomic, copy, nullable) void (^activityHandler)(NSString *peripheralId,
                                                              NSString *name,
                                                              NSString *operation,
                                                              NSString *detail);

/// Feed one decoded protocol message. Call from a single serial queue.
- (void)handleMessage:(NSDictionary<NSString *, id> *)message;

/// Tear down everything the current client owned: stop scanning, cancel
/// connections, close L2CAP channels, and clear all object stores. Call when
/// the client disconnects or is superseded.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
