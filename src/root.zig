// TODO: Modify to try and more closely match the standard tcp connection.
// This means expose a function to create a WebsocketStream, and have similar
// methods as the TCP Stream does.
pub const Client = struct {
    allocator: Allocator,
    stream: ?net.Stream,
    connected: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
    // Create a new WebSocket client
    pub fn init(allocator: Allocator, host: []const u8, port: u16, path: []const u8) !Client {
        return Client{
            .allocator = allocator,
            .connected = false,
            .stream = null,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .path = try allocator.dupe(u8, path),
        };
    }
    // Clean up resources
    pub fn deinit(self: *Client) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        self.allocator.free(self.host);
        self.allocator.free(self.path);
        self.connected = false;
    }
    // Connect to the WebSocket server
    pub fn connect(self: *Client) !void {
        if (self.connected) return;

        const address = try net.Address.parseIp(self.host, self.port);
        self.stream = try net.tcpConnectToAddress(address);

        // Generate the WebSocket key (16 random bytes, base64 encoded)
        var key_bytes: [16]u8 = undefined;
        try std.crypto.random.bytes(&key_bytes);
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

        try self.stream.?.writer().writeAll(request);

        try self.handleHandshakeResponse(key);

        self.connected = true;
    }

    // Process the handshake response from the server
    fn handleHandshakeResponse(self: *Client, client_key: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        var stream_reader = self.stream.?.reader();

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
            if (std.mem.indexOf(u8, header_line, "Sec-WebSocket-Accept:")) |idx| {
                const value_start = idx + "Sec-WebSocket-Accept:".len;
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
};

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const net = std.net;
const base64 = std.base64;
const crypto = std.crypto;
const sha1 = crypto.hash.Sha1;
