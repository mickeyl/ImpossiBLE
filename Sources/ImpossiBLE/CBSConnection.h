#import <Foundation/Foundation.h>

typedef void (^CBSMessageHandler)(NSDictionary *message);
typedef void (^CBSStateHandler)(BOOL connected);

void CBSConnectionSetMessageHandler(CBSMessageHandler handler);
void CBSConnectionSetStateHandler(CBSStateHandler handler);
void CBSConnectionSend(NSDictionary *msg);
void CBSConnectionOpen(void);
BOOL CBSConnectionIsConnected(void);
