pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var wsClient = try websocket.Client.init(allocator, "127.0.0.1", 8080, "/");
    defer wsClient.deinit();
    wsClient.connect() catch |err| {
        std.debug.print("Error connecting to server: {s}\n", .{@errorName(err)});
    };
}

const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Writer = std.net.Stream.Writer;
const Thread = std.Thread;
const websocket = @import("zigsockets");
