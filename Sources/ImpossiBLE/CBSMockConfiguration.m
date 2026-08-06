#import "include/ImpossiBLE.h"
#import "CBSConnection.h"

#if TARGET_OS_SIMULATOR

static BOOL CBSWaitForProvider(NSTimeInterval timeout);

BOOL ImpossiBLESetMockConfiguration(NSData *configurationJSON)
{
    if (configurationJSON.length == 0) return NO;

    NSError *error = nil;
    id configuration = [NSJSONSerialization JSONObjectWithData:configurationJSON
                                                       options:0
                                                         error:&error];
    if (![configuration isKindOfClass:NSDictionary.class]) {
        NSLog(@"ImpossiBLE: mock configuration is not a JSON object: %@", error);
        return NO;
    }

    // A test may upload before it ever touches CoreBluetooth, and the socket is
    // otherwise opened lazily on the first CBCentralManager. Opening is
    // asynchronous, so checking connectivity right afterwards would almost
    // always fail — wait briefly instead of making every caller poll.
    if (!CBSWaitForProvider(2.0)) {
        NSLog(@"ImpossiBLE: no provider connected; mock configuration not sent");
        return NO;
    }

    CBSConnectionSend(@{
        @"type": @"setMockConfiguration",
        @"configuration": configuration,
    });
    return YES;
}

void ImpossiBLEClearMockConfiguration(void)
{
    if (!CBSConnectionIsConnected()) return;
    CBSConnectionSend(@{ @"type": @"clearMockConfiguration" });
}

BOOL ImpossiBLEIsProviderConnected(void)
{
    return CBSWaitForProvider(2.0);
}

/// Opens the socket if needed and waits up to `timeout` for it to come up.
static BOOL CBSWaitForProvider(NSTimeInterval timeout)
{
    CBSConnectionOpen();
    if (CBSConnectionIsConnected()) return YES;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!CBSConnectionIsConnected() && deadline.timeIntervalSinceNow > 0) {
        // Runs the caller's run loop rather than blocking it outright, so this
        // stays safe to call from the main thread during app start-up.
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return CBSConnectionIsConnected();
}

#else

// On a device the bridge is inert, so these are no-ops rather than errors —
// the same test code can run in both places and simply use the real radio.

BOOL ImpossiBLESetMockConfiguration(NSData *configurationJSON) { return NO; }
void ImpossiBLEClearMockConfiguration(void) {}
BOOL ImpossiBLEIsProviderConnected(void) { return NO; }

#endif
