#import "CBSConnection.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#if TARGET_OS_SIMULATOR

static const char *kCBSSocketPath = "/tmp/impossible.sock";
static int gSockFd = -1;
static dispatch_queue_t gReadQueue;
static CBSMessageHandler gMessageHandler;

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
    if (line.length == 0 || !gMessageHandler) {
        return;
    }
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSLog(@"ImpossiBLE: recv type=%@", obj[@"type"]);
        gMessageHandler((NSDictionary *)obj);
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
    });
}

static int cbs_connect(void) {
    if (gSockFd >= 0) {
        return gSockFd;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kCBSSocketPath, sizeof(addr.sun_path) - 1);

    // Retry a few times in case the helper is still starting up.
    for (int attempt = 0; attempt < 5; attempt++) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            NSLog(@"ImpossiBLE: socket() failed");
            return -1;
        }
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            gSockFd = fd;
            cbs_start_reader(fd);
            return fd;
        }
        close(fd);
        if (attempt < 4) {
            usleep(200000);
        }
    }
    NSLog(@"ImpossiBLE: connect(%s) failed after retries", kCBSSocketPath);
    return -1;
}

void CBSConnectionSetMessageHandler(CBSMessageHandler handler) {
    gMessageHandler = [handler copy];
}

void CBSConnectionSend(NSDictionary *msg) {
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
    ssize_t written = write(fd, data.bytes, data.length);
    write(fd, "\n", 1);
    NSLog(@"ImpossiBLE: sent %zd bytes (type=%@)", written, msg[@"type"]);
}

#else

void CBSConnectionSetMessageHandler(CBSMessageHandler handler) {}
void CBSConnectionSend(NSDictionary *msg) {}

#endif
