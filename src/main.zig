pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("MEMORY LEAK DETECTED!\n", .{});
        } else {
            std.debug.print("No memory leaks detected.\n", .{});
        }
    }

    const allocator = gpa.allocator();
    var wsClient = try websocket.Client.init(allocator, "127.0.0.1", 8080, "/");
    defer wsClient.deinit();
    try wsClient.connect();
    if (!wsClient.isConnected()) {
        std.debug.print("Failed to connect\n", .{});
        return;
    }

    var running = std.atomic.Value(bool).init(true);

    const MessageHandler = struct {
        fn handleMessage(message: websocket.protocol.Message) void {
            std.debug.print("Received: {s}\n", .{message.data});
        }
    };

    var messageThread = try wsClient.startMessageLoop(MessageHandler.handleMessage);

    const SenderContext = struct {
        client: *websocket.Client,
        running: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
    };

    const sender_ctx = try allocator.create(SenderContext);
    sender_ctx.* = .{
        .client = &wsClient,
        .running = &running,
        .allocator = allocator,
    };

    const sender_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *SenderContext) void {
            defer ctx.allocator.destroy(ctx);
            var counter: u32 = 0;

            while (ctx.running.load(.acquire)) {
                var message_buf: [64]u8 = undefined;
                const message = std.fmt.bufPrint(&message_buf, "Message #{d}", .{counter}) catch continue;

                ctx.client.sendText(message) catch |err| {
                    std.debug.print("Error sending message: {s}\n", .{@errorName(err)});
                    break;
                };

                std.debug.print("Sent: {s}\n", .{message});
                counter += 1;
                std.time.sleep(1 * std.time.ns_per_s);
            }
        }
    }.run, .{sender_ctx});

    std.debug.print("Press Enter to quit...\n", .{});
    var buffer: [10]u8 = undefined;
    _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(&buffer, '\n');

    running.store(false, .release);

    try wsClient.close(1000, "Normal closure");

    sender_thread.join();
    messageThread.join();
}

const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Writer = std.net.Stream.Writer;
const Thread = std.Thread;
const websocket = @import("zigsockets");
