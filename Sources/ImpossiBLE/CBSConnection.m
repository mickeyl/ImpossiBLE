#import "CBSConnection.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#if TARGET_OS_SIMULATOR

static const char *kCBSSocketPath = "/tmp/impossible.sock";
static int gSockFd = -1;
static dispatch_queue_t gReadQueue;
static dispatch_queue_t gWriteQueue;
static CBSMessageHandler gMessageHandler;
static CBSStateHandler gStateHandler;
static BOOL gConnected = NO;
static BOOL gReconnectDisabled = NO;
static NSString *gPendingDisconnectReason;
static dispatch_source_t gReconnectTimer;

static void cbs_cancel_reconnect_timer(void);
static void cbs_schedule_reconnect(void);
static void cbs_handle_disconnect(int fd);
static void cbs_start_reader(int fd);

static int cbs_find_newline(NSData *data) {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        if (bytes[i] == '\n') {
            return (int)i;
        }
    }
    return -1;
}

static void cbs_handle_line(NSData *line) {
    if (line.length == 0) {
        return;
    }
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *msg = (NSDictionary *)obj;
        NSLog(@"ImpossiBLE: recv type=%@", msg[@"type"]);
        if ([msg[@"type"] isEqualToString:@"connectionRejected"] &&
            [msg[@"code"] isEqualToString:@"clientBusy"]) {
            gReconnectDisabled = YES;
            gPendingDisconnectReason = msg[@"message"] ?: @"provider rejected this process as an additional client";
            cbs_cancel_reconnect_timer();
            NSLog(@"ImpossiBLE: second client rejected — %@; auto-reconnect disabled", gPendingDisconnectReason);
        }
        if (gMessageHandler) {
            gMessageHandler(msg);
        }
    }
}

static void cbs_set_connected(BOOL connected) {
    if (gConnected == connected) return;
    gConnected = connected;
    if (connected) {
        NSLog(@"ImpossiBLE: socket connected");
    }
    CBSStateHandler handler = gStateHandler;
    if (handler) {
        handler(connected);
    }
}

static void cbs_start_reader(int fd) {
    if (gReadQueue) {
        return;
    }
    gReadQueue = dispatch_queue_create("impossible.reader", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gReadQueue, ^{
        NSMutableData *buffer = [NSMutableData data];
        while (1) {
            uint8_t tmp[2048];
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n <= 0) {
                break;
            }
            [buffer appendBytes:tmp length:(NSUInteger)n];
            while (1) {
                int idx = cbs_find_newline(buffer);
                if (idx < 0) {
                    break;
                }
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, (NSUInteger)idx)];
                [buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)idx + 1) withBytes:NULL length:0];
                cbs_handle_line(line);
            }
        }
        cbs_handle_disconnect(fd);
    });
}

static BOOL cbs_write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *ptr = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written <= 0) {
            return NO;
        }
        ptr += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static int cbs_try_connect(void) {
    if (gSockFd >= 0) {
        return gSockFd;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kCBSSocketPath, sizeof(addr.sun_path) - 1);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        gSockFd = fd;
        cbs_start_reader(fd);
        cbs_set_connected(YES);
        return fd;
    }
    close(fd);
    return -1;
}

static int cbs_connect(void) {
    if (gReconnectDisabled) {
        NSLog(@"ImpossiBLE: connect suppressed — previous connection was rejected as an additional client");
        return -1;
    }
    if (gSockFd >= 0) {
        return gSockFd;
    }
    // Retry a few times in case the helper is still starting up.
    for (int attempt = 0; attempt < 5; attempt++) {
        int fd = cbs_try_connect();
        if (fd >= 0) return fd;
        if (attempt < 4) {
            usleep(200000);
        }
    }
    NSLog(@"ImpossiBLE: connect(%s) failed after retries", kCBSSocketPath);
    cbs_schedule_reconnect();
    return -1;
}

static void cbs_handle_disconnect(int fd) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("impossible.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        if (gSockFd != fd) {
            return;
        }
        close(gSockFd);
        gSockFd = -1;
        gReadQueue = nil;
        NSString *reason = gPendingDisconnectReason;
        gPendingDisconnectReason = nil;
        if (reason.length > 0) {
            NSLog(@"ImpossiBLE: socket disconnected (%@)", reason);
        } else {
            NSLog(@"ImpossiBLE: socket disconnected (provider closed connection)");
        }
        cbs_set_connected(NO);
        if (!gReconnectDisabled) {
            cbs_schedule_reconnect();
        }
    });
}

static void cbs_cancel_reconnect_timer(void) {
    if (!gReconnectTimer) return;
    dispatch_source_cancel(gReconnectTimer);
    gReconnectTimer = nil;
}

static void cbs_schedule_reconnect(void) {
    if (gReconnectDisabled) return;
    if (gReconnectTimer) return;
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("impossible.writer", DISPATCH_QUEUE_SERIAL);
    }
    gReconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gWriteQueue);
    dispatch_source_set_timer(gReconnectTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gReconnectTimer, ^{
        if (gReconnectDisabled) {
            cbs_cancel_reconnect_timer();
            return;
        }
        if (gSockFd >= 0) {
            cbs_cancel_reconnect_timer();
            return;
        }
        int fd = cbs_try_connect();
        if (fd >= 0) {
            cbs_cancel_reconnect_timer();
        }
    });
    dispatch_resume(gReconnectTimer);
}

void CBSConnectionSetMessageHandler(CBSMessageHandler handler) {
    gMessageHandler = [handler copy];
}

void CBSConnectionSetStateHandler(CBSStateHandler handler) {
    gStateHandler = [handler copy];
}

BOOL CBSConnectionIsConnected(void) {
    return gConnected;
}

void CBSConnectionOpen(void) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("impossible.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        if (gReconnectDisabled) return;
        if (gSockFd >= 0) return;
        if (cbs_try_connect() < 0) {
            cbs_schedule_reconnect();
        }
    });
}

void CBSConnectionSend(NSDictionary *msg) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("impossible.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        int fd = cbs_connect();
        if (fd < 0) {
            NSLog(@"ImpossiBLE: send failed — not connected");
            return;
        }
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:&error];
        if (!data) {
            NSLog(@"ImpossiBLE: send failed — JSON error: %@", error);
            return;
        }
        if (!cbs_write_all(fd, data.bytes, data.length) || !cbs_write_all(fd, "\n", 1)) {
            NSLog(@"ImpossiBLE: send failed — socket write error");
            cbs_handle_disconnect(fd);
            return;
        }
        NSLog(@"ImpossiBLE: sent %lu bytes (type=%@)", (unsigned long)data.length, msg[@"type"]);
    });
}

#else

void CBSConnectionSetMessageHandler(CBSMessageHandler handler) {}
void CBSConnectionSetStateHandler(CBSStateHandler handler) {}
void CBSConnectionSend(NSDictionary *msg) {}
void CBSConnectionOpen(void) {}
BOOL CBSConnectionIsConnected(void) { return NO; }

#endif
