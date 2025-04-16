// TODO: Modify to try and more closely match the standard tcp connection.
// This means expose a function to create a WebsocketStream, and have similar
// methods as the TCP Stream does.
pub const Client = struct {
    allocator: Allocator,
    websocketStream: ?protocol.WebSocketStream,
    connected: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
    // Create a new WebSocket client
    pub fn init(allocator: Allocator, host: []const u8, port: u16, path: []const u8) !Client {
        return Client{
            .allocator = allocator,
            .connected = false,
            .websocketStream = null,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .path = try allocator.dupe(u8, path),
        };
    }
    // Clean up resources
    pub fn deinit(self: *Client) void {
        if (self.websocketStream) |stream| {
            stream.close(0, "Done") catch {};
            self.websocketStream = null;
        }
        self.allocator.free(self.host);
        self.allocator.free(self.path);
        self.connected = false;
    }
    // Connect to the WebSocket server
    pub fn connect(self: *Client) !void {
        if (self.connected) return;

        const address = try net.Address.parseIp(self.host, self.port);
        const stream = try net.tcpConnectToAddress(address);

        // Generate the WebSocket key (16 random bytes, base64 encoded)
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);
        var key_encoded: [base64.standard.Encoder.calcSize(16)]u8 = undefined;
        const key = base64.standard.Encoder.encode(&key_encoded, &key_bytes);

        const request = try std.fmt.allocPrint(self.allocator, "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n", .{
            self.path,
            self.host,
            self.port,
            key,
        });
        defer self.allocator.free(request);

        try stream.writer().writeAll(request);

        try self.handleHandshakeResponse(&stream, key);

        self.connected = true;
        self.websocketStream = try protocol.WebSocketStream.init(self.allocator, stream);
    }

    // Process the handshake response from the server
    fn handleHandshakeResponse(self: *Client, stream: *const net.Stream, client_key: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        var stream_reader = stream.reader();

        // Read HTTP status line
        const status_line = try stream_reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.ConnectionClosed;

        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) {
            return error.HandshakeRejected;
        }

        // Read headers until we find the empty line that marks the end of headers
        var accept_key_found = false;
        while (true) {
            const header_line = try stream_reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.ConnectionClosed;

            if (header_line.len <= 1) break;

            // Check for Sec-WebSocket-Accept header
            const header_name = "sec-websocket-accept:";
            if (std.ascii.indexOfIgnoreCase(header_line, header_name)) |idx| {
                const value_start = idx + header_name.len;
                const accept_value = std.mem.trim(u8, header_line[value_start..], " \r\n");

                const expected_accept = try computeAcceptKey(self.allocator, client_key);
                defer self.allocator.free(expected_accept);

                if (std.mem.eql(u8, accept_value, expected_accept)) {
                    accept_key_found = true;
                }
            }
        }

        if (!accept_key_found) {
            return error.InvalidHandshakeResponse;
        }
    }

    // Compute the expected accept key for the handshake response
    fn computeAcceptKey(allocator: Allocator, client_key: []const u8) ![]const u8 {
        // The magic string defined in the WebSocket protocol (https://datatracker.ietf.org/doc/html/rfc6455#section-1.2)
        const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

        const key_and_magic = try std.fmt.allocPrint(allocator, "{s}{s}", .{ client_key, magic_string });
        defer allocator.free(key_and_magic);

        // Compute SHA-1 hash
        var hash: [sha1.digest_length]u8 = undefined;
        sha1.hash(key_and_magic, &hash, .{});

        // Base64 encode the hash
        var encoded: [base64.standard.Encoder.calcSize(sha1.digest_length)]u8 = undefined;
        const result = base64.standard.Encoder.encode(&encoded, &hash);

        return allocator.dupe(u8, result);
    }
    // Send a text message
    pub fn sendText(self: *Client, text: []const u8) !void {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;
        try self.websocketStream.?.sendText(text);
    }

    // Send a binary message
    pub fn sendBinary(self: *Client, data: []const u8) !void {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;
        try self.websocketStream.?.sendBinary(data);
    }

    // Read a message (blocking)
    pub fn readMessage(self: *Client) !protocol.Message {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;
        return self.websocketStream.?.readMessage();
    }
    // Check if client is connected
    pub fn isConnected(self: *const Client) bool {
        return self.connected and self.websocketStream != null;
    }
    // Attempt to reconnect
    pub fn reconnect(self: *Client) !void {
        if (self.websocketStream) |*stream| {
            stream.deinit();
            self.websocketStream = null;
        }
        self.connected = false;
        try self.connect();
    }

    // Close the connection with optional status code and reason
    pub fn close(self: *Client, code: u16, reason: ?[]const u8) !void {
        if (!self.connected or self.websocketStream == null) return;
        try self.websocketStream.?.close(code, reason);
        self.connected = false;
    }

    // Send ping with optional data
    pub fn ping(self: *Client, data: ?[]const u8) !void {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;
        try self.websocketStream.?.ping(data);
    }

    // Send pong with optional data
    pub fn pong(self: *Client, data: ?[]const u8) !void {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;
        try self.websocketStream.?.pong(data);
    }
    // Start listening for messages in a separate thread and call the provided callback
    pub fn startMessageLoop(self: *Client, callback: *const fn (protocol.Message) void) !Thread {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;

        const MessageLoopContext = struct {
            client: *Client,
            callback: *const fn (protocol.Message) void,
        };

        const context = try self.allocator.create(MessageLoopContext);
        context.* = .{
            .client = self,
            .callback = callback,
        };

        return try Thread.spawn(.{}, struct {
            fn messageLoop(ctx: *MessageLoopContext) !void {
                defer ctx.client.allocator.destroy(ctx);

                while (ctx.client.isConnected()) {
                    const message = ctx.client.readMessage() catch |err| {
                        if (err == error.ConnectionClosed or err == error.EndOfStream) {
                            break;
                        } else {
                            ctx.client.reconnect() catch break;
                            continue;
                        }
                    };
                    defer ctx.client.allocator.free(message.data);

                    switch (message.type) {
                        .close => {
                            ctx.client.connected = false;
                            break;
                        },
                        .ping => {
                            ctx.client.pong(message.data) catch {};
                            ctx.callback(message);
                        },
                        else => ctx.callback(message),
                    }
                }
            }
        }.messageLoop, .{context});
    }

    // Set a ping interval to keep the connection alive
    pub fn startPingInterval(self: *Client, interval_ms: u64) !Thread {
        if (!self.connected or self.websocketStream == null) return error.NotConnected;

        const PingContext = struct {
            client: *Client,
            interval_ms: u64,
        };

        const context = try self.allocator.create(PingContext);
        context.* = .{
            .client = self,
            .interval_ms = interval_ms,
        };

        return try Thread.spawn(.{}, struct {
            fn pingLoop(ctx: *PingContext) !void {
                defer ctx.client.allocator.destroy(ctx);

                while (ctx.client.isConnected()) {
                    ctx.client.ping(null) catch |err| {
                        if (err == error.ConnectionClosed or err == error.EndOfStream) {
                            break;
                        }
                        ctx.client.reconnect() catch break;
                    };

                    std.time.sleep(ctx.interval_ms * std.time.ns_per_ms);
                }
            }
        }.pingLoop, .{context});
    }
};

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const net = std.net;
const base64 = std.base64;
const crypto = std.crypto;
const sha1 = crypto.hash.Sha1;
pub const protocol = @import("protocol.zig");
const Thread = std.Thread;
