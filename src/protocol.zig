pub const Message = struct {
    type: Type,
    data: []u8,
    allocator: Allocator,

    pub fn deinit(self: *const Message) void {
        self.allocator.free(self.data);
    }

    pub const Type = enum {
        text,
        binary,
        close,
        ping,
        pong,
    };

    pub const TextType = enum {
        text,
        binary,
    };
};

pub const OpCode = enum(u8) {
    text = 128 | 1,
    binary = 128 | 2,
    close = 128 | 8,
    ping = 128 | 9,
    pong = 128 | 10,
};

const FrameHeader = struct {
    isFinal: bool,
    rsv1: bool,
    rsv2: bool,
    rsv3: bool,
    opcode: u4,
    hasMask: bool,
    payloadLength: usize,
    headerSize: usize,
    mask: ?[4]u8,

    pub fn parse(buf: []const u8) ?FrameHeader {
        if (buf.len < 2) {
            return null;
        }

        const b0 = buf[0];
        const b1 = buf[1];

        const isFinal = (b0 & 0x80) != 0;
        const rsv1 = (b0 & 0x40) != 0;
        const rsv2 = (b0 & 0x20) != 0;
        const rsv3 = (b0 & 0x10) != 0;
        const opcode: u4 = @truncate(b0 & 0x0F);

        const hasMask = (b1 & 0x80) != 0;
        var payloadLength: usize = b1 & 0x7F;

        // Determine header size
        var headerSize: usize = 2;

        // Check if we have enough bytes for extended length
        if (payloadLength == 126) {
            if (buf.len < 4) {
                return null;
            }
            payloadLength = @as(usize, buf[2]) << 8 | buf[3];
            headerSize = 4;
        } else if (payloadLength == 127) {
            if (buf.len < 10) {
                return null;
            }
            payloadLength = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                payloadLength = (payloadLength << 8) | buf[2 + i];
            }
            headerSize = 10;
        }

        var mask: ?[4]u8 = null;
        if (hasMask) {
            if (buf.len < headerSize + 4) {
                return null;
            }
            mask = .{
                buf[headerSize],
                buf[headerSize + 1],
                buf[headerSize + 2],
                buf[headerSize + 3],
            };
            headerSize += 4;
        }

        return FrameHeader{
            .isFinal = isFinal,
            .rsv1 = rsv1,
            .rsv2 = rsv2,
            .rsv3 = rsv3,
            .opcode = opcode,
            .hasMask = hasMask,
            .payloadLength = payloadLength,
            .headerSize = headerSize,
            .mask = mask,
        };
    }
};

const FrameCodec = struct {
    allocator: Allocator,
    inBuffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator) !FrameCodec {
        return FrameCodec{ .allocator = allocator, .inBuffer = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *FrameCodec) void {
        self.inBuffer.deinit();
    }

    fn readFrame(self: *FrameCodec, stream: Stream) !Frame {
        var header: ?FrameHeader = null;

        // Keep reading until we have a complete frame
        while (true) {
            header = FrameHeader.parse(self.inBuffer.items);

            // If we have a header, check if we have enough data for the full frame
            if (header) |hdr| {
                const totalFrameSize = hdr.headerSize + hdr.payloadLength;

                // If we have the full frame, extract it and return
                if (self.inBuffer.items.len >= totalFrameSize) {
                    var payload = try self.allocator.alloc(u8, hdr.payloadLength);
                    errdefer self.allocator.free(payload);
                    @memcpy(payload, self.inBuffer.items[hdr.headerSize..totalFrameSize]);

                    if (hdr.mask) |mask| {
                        var i: usize = 0;
                        while (i < payload.len) : (i += 1) {
                            payload[i] ^= mask[i % 4];
                        }
                    }

                    var newBuffer = std.ArrayList(u8).init(self.allocator);
                    try newBuffer.appendSlice(self.inBuffer.items[totalFrameSize..]);
                    errdefer self.allocator.free(newBuffer);

                    const oldBuffer = self.inBuffer;
                    self.inBuffer = newBuffer;
                    oldBuffer.deinit();

                    return Frame{
                        .header = hdr,
                        .payload = payload,
                    };
                }
            }

            // We need more data, read from the stream
            var newBuffer: [1024]u8 = undefined;
            const bytesRead = try stream.read(&newBuffer);

            if (bytesRead == 0) {
                return error.EndOfStream;
            }

            try self.inBuffer.appendSlice(newBuffer[0..bytesRead]);
        }
    }
};

const Frame = struct {
    header: FrameHeader,
    payload: []u8,
};

pub const WebSocketContext = struct {
    frameCodec: FrameCodec,
    fragmented_message: ?struct {
        type: Message.Type,
        data: std.ArrayList(u8),
    },
    allocator: Allocator,

    pub fn init(allocator: Allocator) !WebSocketContext {
        return WebSocketContext{
            .frameCodec = try FrameCodec.init(allocator),
            .fragmented_message = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketContext) void {
        if (self.fragmented_message) |*frag| {
            frag.data.deinit();
        }
        self.frameCodec.deinit();
    }

    // Reads a complete message from the websocket
    pub fn readMessage(self: *WebSocketContext, stream: Stream) !Message {
        while (true) {
            const frame = try self.frameCodec.readFrame(stream);
            defer self.allocator.free(frame.payload);

            // Handle control frames immediately
            switch (frame.header.opcode) {
                0x8 => { // Close frame
                    return Message{
                        .type = .close,
                        .data = try self.allocator.dupe(u8, frame.payload),
                        .allocator = self.allocator,
                    };
                },
                0x9 => { // Ping frame
                    return Message{
                        .type = .ping,
                        .data = try self.allocator.dupe(u8, frame.payload),
                        .allocator = self.allocator,
                    };
                },
                0xA => { // Pong frame
                    return Message{
                        .type = .pong,
                        .data = try self.allocator.dupe(u8, frame.payload),
                        .allocator = self.allocator,
                    };
                },
                0x0 => { // Continuation frame
                    if (self.fragmented_message) |*frag| {
                        try frag.data.appendSlice(frame.payload);

                        if (frame.header.isFinal) {
                            const complete_message = Message{
                                .type = frag.type,
                                .data = try frag.data.toOwnedSlice(),
                                .allocator = self.allocator,
                            };

                            self.fragmented_message = null;
                            return complete_message;
                        }
                    } else {
                        return error.UnexpectedContinuationFrame;
                    }
                },
                0x1, 0x2 => { // Text or binary frame
                    const message_type = if (frame.header.opcode == 0x1) Message.Type.text else Message.Type.binary;

                    if (frame.header.isFinal) {
                        return Message{
                            .type = message_type,
                            .data = try self.allocator.dupe(u8, frame.payload),
                            .allocator = self.allocator,
                        };
                    } else {
                        // Start of a fragmented message
                        if (self.fragmented_message != null) {
                            return error.UnexpectedStartOfFragment;
                        }

                        var data = std.ArrayList(u8).init(self.allocator);
                        try data.appendSlice(frame.payload);

                        self.fragmented_message = .{
                            .type = message_type,
                            .data = data,
                        };
                    }
                },
                else => {
                    return error.InvalidOpcode;
                },
            }
        }
    }

    // Writes a message to the websocket
    // FIXME: Add framing
    pub fn writeMessage(self: *const WebSocketContext, stream: Stream, message: Message) !void {
        const opcode: u4 = switch (message.type) {
            .text => 0x1,
            .binary => 0x2,
            .close => 0x8,
            .ping => 0x9,
            .pong => 0xA,
        };

        try self.writeFrame(stream, .{
            .isFinal = true,
            .opcode = opcode,
            .payload = message.data,
        });
    }

    // Helper function to write a frame
    fn writeFrame(
        self: *const WebSocketContext,
        stream: Stream,
        frame: struct {
            isFinal: bool,
            opcode: u4,
            payload: []const u8,
            mask: bool = true,
        },
    ) !void {
        // Calculate header size
        var headerSize: usize = 2; // Basic header is 2 bytes

        // Calculate extended length bytes
        if (frame.payload.len > 125 and frame.payload.len <= 65535) {
            headerSize += 2;
        } else if (frame.payload.len > 65535) {
            headerSize += 8;
        }

        // Add 4 bytes for mask if masking is enabled
        var maskBytes: ?[4]u8 = null;
        if (frame.mask) {
            headerSize += 4;
            var rnd = std.crypto.random;
            var mask: [4]u8 = undefined;
            rnd.bytes(&mask);
            maskBytes = mask;
        }

        var header = try self.allocator.alloc(u8, headerSize);
        defer self.allocator.free(header);

        // Set first byte (FIN, RSV1-3, OPCODE)
        header[0] = if (frame.isFinal) 0x80 else 0;
        header[0] |= frame.opcode;

        // Set second byte with mask bit if needed
        var secondByte: u8 = 0;
        if (frame.mask) {
            secondByte |= 0x80;
        }

        // Set length bytes
        const payloadLength: u8 = @intCast(frame.payload.len);
        if (frame.payload.len <= 125) {
            header[1] = secondByte | payloadLength;
        } else if (frame.payload.len <= 65535) {
            header[1] = secondByte | 126;
            header[2] = @intCast((frame.payload.len >> 8) & 0xFF);
            header[3] = @intCast(frame.payload.len & 0xFF);
        } else {
            header[1] = secondByte | 127;
            // taken from (https://github.com/karlseguin/websocket.zig)
            if (comptime builtin.target.ptrBitWidth() >= 64) {
                header[2] = @intCast((frame.payload.len >> 56) & 0xFF);
                header[3] = @intCast((frame.payload.len >> 48) & 0xFF);
                header[4] = @intCast((frame.payload.len >> 40) & 0xFF);
                header[5] = @intCast((frame.payload.len >> 32) & 0xFF);
            } else {
                header[2] = 0;
                header[3] = 0;
                header[4] = 0;
                header[5] = 0;
            }
            header[6] = @intCast((frame.payload.len >> 24) & 0xFF);
            header[7] = @intCast((frame.payload.len >> 16) & 0xFF);
            header[8] = @intCast((frame.payload.len >> 8) & 0xFF);
            header[9] = @intCast(frame.payload.len & 0xFF);
        }

        // Add mask bytes to header if masking
        var maskOffset: usize = 0;
        if (frame.mask) {
            if (frame.payload.len <= 125) {
                maskOffset = 2;
            } else if (frame.payload.len <= 65535) {
                maskOffset = 4;
            } else {
                maskOffset = 10;
            }

            header[maskOffset] = maskBytes.?[0];
            header[maskOffset + 1] = maskBytes.?[1];
            header[maskOffset + 2] = maskBytes.?[2];
            header[maskOffset + 3] = maskBytes.?[3];
        }
        _ = try stream.write(header);

        if (frame.mask and maskBytes != null) {
            var maskedPayload = try self.allocator.alloc(u8, frame.payload.len);
            defer self.allocator.free(maskedPayload);
            for (frame.payload, 0..) |byte, i| {
                maskedPayload[i] = byte ^ maskBytes.?[i % 4];
            }
            _ = try stream.write(maskedPayload);
        } else {
            _ = try stream.write(frame.payload);
        }
    }
};

pub const WebSocketStream = struct {
    context: WebSocketContext,
    stream: Stream,
    allocator: Allocator,

    pub fn init(allocator: Allocator, stream: Stream) !WebSocketStream {
        return WebSocketStream{
            .context = try WebSocketContext.init(allocator),
            .stream = stream,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketStream) void {
        self.context.deinit();
    }

    // Read a message from the websocket
    pub fn readMessage(self: *WebSocketStream) !Message {
        return self.context.readMessage(self.stream);
    }

    // Write a message to the websocket
    pub fn writeMessage(self: *const WebSocketStream, message: Message) !void {
        try self.context.writeMessage(self.stream, message);
    }

    // Convenience method to send a text message
    pub fn sendText(self: *WebSocketStream, text: []const u8) !void {
        const message = Message{ .type = .text, .data = try self.allocator.dupe(u8, text), .allocator = self.allocator };
        defer message.deinit();

        try self.writeMessage(message);
    }

    // Convenience method to send a binary message
    pub fn sendBinary(self: *WebSocketStream, data: []const u8) !void {
        const message = Message{ .type = .binary, .data = try self.allocator.dupe(u8, data), .allocator = self.allocator };
        defer message.deinit();

        try self.writeMessage(message);
    }

    // Send a close frame with optional reason
    pub fn close(self: *const WebSocketStream, code: u16, reason: ?[]const u8) !void {
        var payload_len: usize = 2; // Status code is 2 bytes
        if (reason) |r| {
            payload_len += r.len;
        }

        var payload = try self.allocator.alloc(u8, payload_len);

        payload[0] = @truncate((code >> 8) & 0xFF);
        payload[1] = @truncate(code & 0xFF);

        // Add optional reason
        if (reason) |r| {
            @memcpy(payload[2..], r);
        }

        const message = Message{ .type = .close, .data = payload, .allocator = self.allocator };
        defer message.deinit();

        try self.writeMessage(message);
    }

    // Send a ping with optional data
    pub fn ping(self: *WebSocketStream, data: ?[]const u8) !void {
        const message = Message{
            .type = .ping,
            .data = if (data) |d|
                try self.allocator.dupe(u8, d)
            else
                &[_]u8{},
            .allocator = self.allocator,
        };
        defer message.deinit();

        try self.writeMessage(message);
    }

    // Send a pong with optional data (usually in response to a ping)
    pub fn pong(self: *WebSocketStream, data: ?[]const u8) !void {
        const message = Message{
            .type = .pong,
            .data = if (data) |d|
                try self.allocator.dupe(u8, d)
            else
                &[_]u8{},
            .allocator = self.allocator,
        };

        defer message.deinit();

        try self.writeMessage(message);
    }
};

const std = @import("std");
const Stream = std.net.Stream;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
