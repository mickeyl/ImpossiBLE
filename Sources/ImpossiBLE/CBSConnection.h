#import <Foundation/Foundation.h>

typedef void (^CBSMessageHandler)(NSDictionary *message);

void CBSConnectionSetMessageHandler(CBSMessageHandler handler);
void CBSConnectionSend(NSDictionary *msg);
