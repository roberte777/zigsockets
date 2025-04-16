pub fn main() !void {
    const peer = try net.Address.parseIp4("127.0.0.1", 8080);
    // Connect to peer
    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    print("Connecting to {}\n", .{peer});

    // Sending data to peer
    const writer = stream.writer();
    const writer2 = stream.writer();
    const thread1 = try Thread.spawn(.{}, write_message, .{writer});
    const thread2 = try Thread.spawn(.{}, write_message, .{writer2});
    thread1.join();
    thread2.join();
}

pub fn write_message(writer: Writer) !void {
    const data = "hello zig";
    const size = try writer.write(data);
    print("Sending '{s}' to peer, total written: {d} bytes\n", .{ data, size });
}
const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Writer = std.net.Stream.Writer;
const Thread = std.Thread;
