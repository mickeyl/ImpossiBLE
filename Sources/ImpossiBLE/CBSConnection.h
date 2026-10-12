#import <Foundation/Foundation.h>

typedef void (^CBSMessageHandler)(NSDictionary *message);
typedef void (^CBSStateHandler)(BOOL connected);

void CBSConnectionSetMessageHandler(CBSMessageHandler handler);
void CBSConnectionSetStateHandler(CBSStateHandler handler);
void CBSConnectionSend(NSDictionary *msg);
void CBSConnectionOpen(void);
/// Runs the block on the connection's queue, after any open already requested has
/// connected or failed. Connection state changes are reported on the same queue.
void CBSConnectionAfterPendingOpen(dispatch_block_t block);
BOOL CBSConnectionIsConnected(void);
