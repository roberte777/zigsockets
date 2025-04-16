pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var wsClient = try websocket.Client.init(allocator, "127.0.0.1", 8080, "/");
    defer wsClient.deinit();

    try wsClient.connect();

    if (!wsClient.isConnected()) {
        std.debug.print("Failed to connect\n", .{});
        return;
    }

    // Define a message handler
    // const MessageHandler = struct {
    //     fn handleMessage(message: websocket.protocol.Message) void {
    //         switch (message.type) {
    //             .text => {
    //                 const text = message.data;
    //                 std.debug.print("Received text: {s}\n", .{text});
    //             },
    //             .binary => {
    //                 std.debug.print("Received binary message ({d} bytes)\n", .{message.data.len});
    //             },
    //             .ping => {
    //                 std.debug.print("Received ping\n", .{});
    //             },
    //             .pong => {
    //                 std.debug.print("Received pong\n", .{});
    //             },
    //             .close => {
    //                 std.debug.print("Received close frame\n", .{});
    //             },
    //         }
    //     }
    // };

    // // Start listening for messages in a separate thread
    // var messageThread = try wsClient.startMessageLoop(MessageHandler.handleMessage);
    //
    // // Start automatic ping interval
    // var pingThread = try wsClient.startPingInterval(30000); // 30 seconds

    // Send a text message
    try wsClient.sendText("Hello, WebSocket server!");
    const message = try wsClient.readMessage();
    std.debug.print("message: {s}\n", .{message.data});

    // Wait for user input to quit
    std.debug.print("Press Enter to quit...\n", .{});
    var buffer: [10]u8 = undefined;
    _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(&buffer, '\n');

    // Close the connection gracefully
    try wsClient.close(1000, "Normal closure");

    // Wait for the threads to finish
    // messageThread.join();
    // pingThread.join();
}

const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Writer = std.net.Stream.Writer;
const Thread = std.Thread;
comptime {
    _ = @import("zigsockets");
}
const websocket = @import("zigsockets");
