const std = @import("std");

const MAX_HISTORY: usize = 500;
const MAX_PARTICIPANTS: usize = 4;
const Allocator = std.mem.Allocator;

const MessageQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    allocator: Allocator,
    items: std.ArrayList(ServerMessage),
    stopped: bool = false,

    fn init(allocator: Allocator) MessageQueue {
        return .{ .allocator = allocator, .items = std.ArrayList(ServerMessage).init(allocator) };
    }

    fn deinit(self: *MessageQueue) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit();
    }

    fn push(self: *MessageQueue, msg: ServerMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.QueueClosed;
        try self.items.append(msg);
        self.cond.signal();
    }

    fn pop(self: *MessageQueue) !ServerMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.items.items.len == 0) {
            if (self.stopped) return error.QueueClosed;
            self.cond.wait(&self.mutex);
        }
        return self.items.orderedRemove(0);
    }

    fn tryPop(self: *MessageQueue) ?ServerMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    fn stop(self: *MessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
        self.cond.broadcast();
    }
};

const Participant = struct {
    id: []const u8,
    queue: *MessageQueue,
};

const Room = struct {
    id: []const u8,
    participants: std.ArrayList(Participant),
    messages: std.StringHashMap(std.ArrayList([]u8)),
    last_update: i128,
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: Allocator, id: []const u8) !Room {
        return Room{
            .id = try allocator.dupe(u8, id),
            .participants = std.ArrayList(Participant).init(allocator),
            .messages = std.StringHashMap(std.ArrayList([]u8)).init(allocator),
            .last_update = std.time.nanoTimestamp(),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Room) void {
        for (self.participants.items) |p| {
            self.allocator.free(p.id);
        }
        self.participants.deinit();

        var it = self.messages.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |line| {
                self.allocator.free(line);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.messages.deinit();
        self.allocator.free(self.id);
    }

    fn join(self: *Room, participant_id: []const u8, queue: *MessageQueue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.participants.items.len >= MAX_PARTICIPANTS) {
            return error.RoomIsFull;
        }

        try self.participants.append(.{ .id = try self.allocator.dupe(u8, participant_id), .queue = queue });
        const timestamp = std.time.timestamp();

        if (!self.messages.contains(participant_id)) {
            var list = std.ArrayList([]u8).init(self.allocator);
            const ts = try fmtTimestamp(self.allocator, timestamp);
            defer self.allocator.free(ts);
            try list.append(try std.fmt.allocPrint(self.allocator, "> {s} has joined at {s}Z", .{
                participant_id[0..@min(participant_id.len, 4)],
                ts,
            }));
            try list.append(try self.allocator.dupe(u8, ""));
            try self.messages.put(try self.allocator.dupe(u8, participant_id), list);
        } else {
            if (self.messages.get(participant_id)) |list_ptr| {
                const ts = try fmtTimestamp(self.allocator, timestamp);
                defer self.allocator.free(ts);
                try list_ptr.append(try std.fmt.allocPrint(self.allocator, "> {s} has joined at {s}Z", .{
                    participant_id[0..@min(participant_id.len, 4)],
                    ts,
                }));
                try list_ptr.append(try self.allocator.dupe(u8, ""));
                self.pruneHistory(participant_id);
            }
        }
        self.last_update = std.time.nanoTimestamp();
    }

    fn leave(self: *Room, participant_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.participants.retain(|p| !std.mem.eql(u8, p.id, participant_id));
        const timestamp = std.time.timestamp();
        if (self.messages.get(participant_id)) |list_ptr| {
            const ts = fmtTimestamp(self.allocator, timestamp) catch return;
            defer self.allocator.free(ts);
            list_ptr.append(std.fmt.allocPrint(self.allocator, "> {s} has left at {s}Z", .{
                participant_id[0..@min(participant_id.len, 4)],
                ts,
            }) catch return;
            list_ptr.append(self.allocator.dupe(u8, "") catch return);
            self.pruneHistory(participant_id);
        }
        self.last_update = std.time.nanoTimestamp();
    }

    fn pruneHistory(self: *Room, participant_id: []const u8) void {
        // Caller holds the mutex.
        if (self.messages.get(participant_id)) |list_ptr| {
            if (list_ptr.items.len > MAX_HISTORY) {
                const remove_count = list_ptr.items.len - MAX_HISTORY;
                for (list_ptr.items[0..remove_count]) |line| {
                    self.allocator.free(line);
                }
                list_ptr.items = list_ptr.items[remove_count..];
            }
        }
    }

    fn broadcast(self: *Room, message: ServerMessage, exclude_id: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.participants.items) |p| {
            if (exclude_id) |ex| {
                if (std.mem.eql(u8, ex, p.id)) continue;
            }
            // Ignore failures; disconnected participants will be cleaned up by callers.
            _ = p.queue.push(message.clone(self.allocator)) catch {};
        }
    }

    fn notifyParticipants(self: *Room, exclude_id: ?[]const u8) void {
        self.mutex.lock();
        var ids = std.ArrayList([]const u8).init(self.allocator);
        defer ids.deinit();
        for (self.participants.items) |p| {
            if (exclude_id) |ex| if (std.mem.eql(u8, ex, p.id)) continue;
            ids.append(self.allocator.dupe(u8, p.id) catch continue) catch {};
        }
        self.mutex.unlock();

        for (ids.items) |pid| {
            const view = self.render(pid) catch continue;
            var msg = ServerMessage{ .got_room = view };
            self.broadcast(msg, pid);
            msg.deinit(self.allocator);
            self.allocator.free(pid);
        }
    }

    fn render(self: *Room, socket_id: []const u8) !RoomView {
        self.mutex.lock();
        var other = std.ArrayList([]const u8).init(self.allocator);
        for (self.participants.items) |p| {
            if (!std.mem.eql(u8, p.id, socket_id)) {
                try other.append(p.id);
            }
        }
        const view = RoomView{
            .messages = try duplicateMessages(self.allocator, &self.messages),
            .participants = self.participants.items.len,
            .id = self.id,
            .your_id = socket_id,
            .their_id = if (other.items.len > 0) other.items[0] else null,
            .other_participant_ids = other.items,
        };
        self.mutex.unlock();
        return view;
    }
};

const RoomView = struct {
    messages: std.StringHashMap(std.ArrayList([]u8)),
    participants: usize,
    id: []const u8,
    your_id: []const u8,
    their_id: ?[]const u8,
    other_participant_ids: []const []const u8,

    fn deinit(self: *RoomView, allocator: Allocator) void {
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |line| allocator.free(line);
            entry.value_ptr.deinit();
            allocator.free(entry.key_ptr.*);
        }
        self.messages.deinit();
        allocator.free(self.other_participant_ids);
    }
};

const ServerMessage = union(enum) {
    got_room: RoomView,
    room_is_crowded: struct { message: []const u8 },
    committed: struct { final: []const u8, source: []const u8 },
    key_press: struct { key: []const u8, source: []const u8, cursor_pos: ?usize },

    fn deinit(self: *ServerMessage, allocator: Allocator) void {
        switch (self.*) {
            .got_room => |*view| view.deinit(allocator),
            .room_is_crowded => |payload| allocator.free(payload.message),
            .committed => |payload| allocator.free(payload.final),
            .key_press => |payload| allocator.free(payload.key),
        }
    }

    fn clone(self: ServerMessage, allocator: Allocator) !ServerMessage {
        return switch (self) {
            .got_room => |view| .{ .got_room = try duplicateRoomView(allocator, &view) },
            .room_is_crowded => |payload| .{ .room_is_crowded = .{ .message = try allocator.dupe(u8, payload.message) } },
            .committed => |payload| .{ .committed = .{ .final = try allocator.dupe(u8, payload.final), .source = payload.source } },
            .key_press => |payload| .{ .key_press = .{ .key = try allocator.dupe(u8, payload.key), .source = payload.source, .cursor_pos = payload.cursor_pos } },
        };
    }
};

const ClientMessage = union(enum) {
    newroom: struct { socket_id: ?[]const u8 },
    fetchRoom: struct { id: []const u8, socket_id: ?[]const u8 },
    keyPress: struct { key: []const u8, cursor_pos: ?usize },
};

const AppState = struct {
    allocator: Allocator,
    rooms_mutex: std.Thread.Mutex = .{},
    rooms: std.StringHashMap(*Room),

    fn init(allocator: Allocator) AppState {
        return .{ .allocator = allocator, .rooms = std.StringHashMap(*Room).init(allocator) };
    }

    fn deinit(self: *AppState) void {
        var it = self.rooms.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.rooms.deinit();
    }
};

fn fmtTimestamp(allocator: Allocator, ts: i64) ![]u8 {
    const seconds = @intCast(u64, ts);
    const dt = std.time.timestampToDatetime(seconds, 0) catch return allocator.dupe(u8, "unknown");
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    });
}

fn duplicateMessages(allocator: Allocator, source: *const std.StringHashMap(std.ArrayList([]u8))) !std.StringHashMap(std.ArrayList([]u8)) {
    var dup = std.StringHashMap(std.ArrayList([]u8)).init(allocator);
    var it = source.iterator();
    while (it.next()) |entry| {
        var lines = std.ArrayList([]u8).init(allocator);
        for (entry.value_ptr.items) |line| {
            try lines.append(try allocator.dupe(u8, line));
        }
        try dup.put(try allocator.dupe(u8, entry.key_ptr.*), lines);
    }
    return dup;
}

fn duplicateRoomView(allocator: Allocator, view: *const RoomView) !RoomView {
    return RoomView{
        .messages = try duplicateMessages(allocator, &view.messages),
        .participants = view.participants,
        .id = view.id,
        .your_id = view.your_id,
        .their_id = view.their_id,
        .other_participant_ids = try allocator.dupe([]const u8, view.other_participant_ids),
    };
}

fn generateRandomString(allocator: Allocator, len: usize) ![]u8 {
    var buf = try allocator.alloc(u8, len);
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var prng = std.rand.DefaultPrng.init(@as(u64, @bitCast(std.time.nanoTimestamp())));
    const random = prng.random();
    for (buf) |*b| b.* = charset[random.intRangeLessThan(usize, 0, charset.len)];
    return buf;
}

fn isNonEvent(key: []const u8) bool {
    return std.mem.eql(u8, key, "Shift") or std.mem.eql(u8, key, "Meta") or std.mem.eql(u8, key, "Control") or
        std.mem.eql(u8, key, "Alt") or std.mem.eql(u8, key, "Enter") or std.mem.eql(u8, key, "Escape") or
        std.mem.eql(u8, key, "Backspace") or std.mem.eql(u8, key, "ArrowLeft") or std.mem.eql(u8, key, "ArrowRight") or
        std.mem.eql(u8, key, "ArrowUp") or std.mem.eql(u8, key, "ArrowDown") or std.mem.eql(u8, key, "Tab") or
        std.mem.eql(u8, key, "Delete") or std.mem.eql(u8, key, "DeleteAt") or std.mem.eql(u8, key, "CtrlA") or
        std.mem.eql(u8, key, "CtrlE") or std.mem.eql(u8, key, "CtrlK") or std.mem.eql(u8, key, "CtrlB") or
        std.mem.eql(u8, key, "CtrlF");
}

fn applyKeyPress(room: *Room, participant_id: []const u8, key: []const u8, cursor_pos: ?usize) void {
    room.broadcast(ServerMessage{ .key_press = .{ .key = key, .source = participant_id, .cursor_pos = cursor_pos } }, participant_id);
    if (room.messages.get(participant_id)) |list_ptr| {
        if (list_ptr.items.len == 0) return;
        const current_line = &list_ptr.items[list_ptr.items.len - 1];
        if (std.mem.eql(u8, key, "Enter")) {
            const final_line = current_line.*;
            room.broadcast(ServerMessage{ .committed = .{ .final = final_line, .source = participant_id } }, participant_id);
            list_ptr.append(room.allocator.dupe(u8, "") catch return);
            room.pruneHistory(participant_id);
            return;
        }
        if (cursor_pos) |pos| {
            if (std.mem.eql(u8, key, "CtrlK")) {
                if (pos <= current_line.len) current_line.* = current_line.*[0..pos];
            } else if ((std.mem.eql(u8, key, "DeleteAt") or std.mem.eql(u8, key, "Delete")) and pos < current_line.len) {
                var buf = std.ArrayList(u8).fromOwnedSlice(room.allocator, current_line.*) catch return;
                _ = buf.orderedRemove(pos);
                current_line.* = buf.toOwnedSlice();
            } else if (std.mem.eql(u8, key, "Backspace")) {
                if (pos > 0 and pos <= current_line.len) {
                    var buf = std.ArrayList(u8).fromOwnedSlice(room.allocator, current_line.*) catch return;
                    _ = buf.orderedRemove(pos - 1);
                    current_line.* = buf.toOwnedSlice();
                }
            } else if (std.mem.eql(u8, key, "Space")) {
                if (pos <= current_line.len) {
                    var buf = std.ArrayList(u8).fromOwnedSlice(room.allocator, current_line.*) catch return;
                    _ = buf.insert(pos, ' ') catch return;
                    current_line.* = buf.toOwnedSlice();
                }
            } else if (!isNonEvent(key) and key.len == 1 and pos <= current_line.len) {
                var buf = std.ArrayList(u8).fromOwnedSlice(room.allocator, current_line.*) catch return;
                _ = buf.insert(pos, key[0]) catch return;
                current_line.* = buf.toOwnedSlice();
            }
        }
    }
    room.last_update = std.time.nanoTimestamp();
}

fn serializeServerMessage(allocator: Allocator, message: ServerMessage) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    var stream = buffer.writer();
    var jw = std.json.Writer.init(stream); // default minified output
    try jw.beginObject();
    switch (message) {
        .got_room => |room_view| {
            try jw.objectField("type");
            try jw.write("gotRoom");
            try jw.objectField("room");
            try jw.beginObject();

            try jw.objectField("messages");
            try jw.beginObject();
            var it = room_view.messages.iterator();
            while (it.next()) |entry| {
                try jw.objectField(entry.key_ptr.*);
                try jw.beginArray();
                for (entry.value_ptr.items) |line| {
                    try jw.write(line);
                }
                try jw.endArray();
            }
            try jw.endObject();

            try jw.objectField("participants");
            try jw.write(room_view.participants);
            try jw.objectField("id");
            try jw.write(room_view.id);
            try jw.objectField("yourId");
            try jw.write(room_view.your_id);
            try jw.objectField("theirId");
            if (room_view.their_id) |other| {
                try jw.write(other);
            } else {
                try jw.write(std.json.Value.null);
            }
            try jw.objectField("otherParticipantIds");
            try jw.beginArray();
            for (room_view.other_participant_ids) |pid| try jw.write(pid);
            try jw.endArray();

            try jw.endObject();
        },
        .room_is_crowded => |payload| {
            try jw.objectField("type");
            try jw.write("room-is-crowded");
            try jw.objectField("message");
            try jw.write(payload.message);
        },
        .committed => |payload| {
            try jw.objectField("type");
            try jw.write("committed");
            try jw.objectField("final");
            try jw.write(payload.final);
            try jw.objectField("source");
            try jw.write(payload.source);
        },
        .key_press => |payload| {
            try jw.objectField("type");
            try jw.write("keyPress");
            try jw.objectField("key");
            try jw.write(payload.key);
            try jw.objectField("source");
            try jw.write(payload.source);
            try jw.objectField("cursorPos");
            if (payload.cursor_pos) |pos| {
                try jw.write(pos);
            } else {
                try jw.write(std.json.Value.null);
            }
        },
    }
    try jw.endObject();
    return buffer.toOwnedSlice();
}

fn parseClientMessage(allocator: Allocator, text: []const u8) !ClientMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object orelse return error.InvalidMessage;
    const kind = obj.get("type") orelse return error.InvalidMessage;
    const kind_str = kind.string orelse return error.InvalidMessage;

    if (std.mem.eql(u8, kind_str, "newroom")) {
        const socket_val = obj.get("socketId");
        return ClientMessage{ .newroom = .{ .socket_id = if (socket_val) |val| val.string else null } };
    } else if (std.mem.eql(u8, kind_str, "fetchRoom")) {
        const id_val = obj.get("id") orelse return error.InvalidMessage;
        const room_id = id_val.string orelse return error.InvalidMessage;
        const socket_val = obj.get("socketId");
        return ClientMessage{ .fetchRoom = .{ .id = room_id, .socket_id = if (socket_val) |val| val.string else null } };
    } else if (std.mem.eql(u8, kind_str, "keyPress")) {
        const key_val = obj.get("key") orelse return error.InvalidMessage;
        const key = key_val.string orelse return error.InvalidMessage;
        const cursor_val = obj.get("cursorPos");
        const cursor = if (cursor_val) |val| val.integerAs(usize) catch null else null;
        return ClientMessage{ .keyPress = .{ .key = key, .cursor_pos = cursor } };
    }
    return error.InvalidMessage;
}

fn sendHttpResponse(stream: anytype, status_line: []const u8, headers: []const u8, body: []const u8) !void {
    var writer = stream.writer();
    try writer.writeAll(status_line);
    try writer.writeAll(headers);
    try writer.writeAll("Content-Length: ");
    try writer.print("{d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

fn websocketHandshake(stream: anytype, request_headers: []const u8) !void {
    const key_marker = "Sec-WebSocket-Key:";
    const key_line = std.mem.indexOf(u8, request_headers, key_marker) orelse return error.InvalidHandshake;
    const key_start = key_line + key_marker.len;
    const key_end = std.mem.indexOf(u8, request_headers[key_start..], "\r\n") orelse return error.InvalidHandshake;
    const raw_key = std.mem.trim(u8, request_headers[key_start .. key_start + key_end], " \t");
    const combined = try std.fmt.allocPrint(std.heap.page_allocator, "{s}258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .{raw_key});
    defer std.heap.page_allocator.free(combined);

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(combined);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);

    var accept_buf: [28]u8 = undefined;
    const accept_len = std.base64.standard.Encoder.encode(&accept_buf, &digest);
    const accept = accept_buf[0..accept_len];

    var writer = stream.writer();
    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\nConnection: Upgrade\r\n");
    try writer.writeAll("Sec-WebSocket-Accept: ");
    try writer.writeAll(accept);
    try writer.writeAll("\r\n\r\n");
}

fn readFrame(reader: anytype, allocator: Allocator) !?[]u8 {
    var header: [2]u8 = undefined;
    if (try reader.readAll(&header) != 2) return null;
    const opcode = header[0] & 0x0F;
    if (opcode == 0x8) return null;
    const masked = (header[1] & 0x80) != 0;
    var length: usize = (header[1] & 0x7F);
    if (length == 126) {
        var extended: [2]u8 = undefined;
        _ = try reader.readAll(&extended);
        length = @intCast(u16, std.mem.readInt(u16, &extended, .big));
    } else if (length == 127) {
        var extended: [8]u8 = undefined;
        _ = try reader.readAll(&extended);
        length = @intCast(usize, std.mem.readInt(u64, &extended, .big));
    }
    var masking_key: [4]u8 = undefined;
    if (masked) {
        _ = try reader.readAll(&masking_key);
    }
    var payload = try allocator.alloc(u8, length);
    if (try reader.readAll(payload) != length) return null;
    if (masked) {
        for (payload, 0..) |*b, idx| b.* ^= masking_key[idx % 4];
    }
    if (opcode != 0x1) return payload; // treat binary as-is
    return payload;
}

fn writeFrame(stream: anytype, payload: []const u8) !void {
    var writer = stream.writer();
    var header: [2]u8 = .{0x81, 0};
    if (payload.len < 126) {
        header[1] = @intCast(u8, payload.len);
        try writer.writeAll(&header);
    } else if (payload.len < 65536) {
        header[1] = 126;
        try writer.writeAll(&header);
        var extended: [2]u8 = undefined;
        std.mem.writeInt(u16, &extended, @intCast(u16, payload.len), .big);
        try writer.writeAll(&extended);
    } else {
        header[1] = 127;
        try writer.writeAll(&header);
        var extended: [8]u8 = undefined;
        std.mem.writeInt(u64, &extended, @intCast(u64, payload.len), .big);
        try writer.writeAll(&extended);
    }
    try writer.writeAll(payload);
}

fn outboundLoop(queue: *MessageQueue, stream: anytype, allocator: Allocator) void {
    while (true) {
        var msg = queue.pop() catch break;
        const payload = serializeServerMessage(allocator, msg) catch {
            msg.deinit(allocator);
            continue;
        };
        msg.deinit(allocator);
        const result = writeFrame(stream, payload);
        allocator.free(payload);
        if (result) |_| {} else |err| {
            std.log.warn("stopping sender: {s}", .{@errorName(err)});
            break;
        }
    }
}

fn staticContentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "text/html";
}

fn serveStatic(stream: anytype, target: []const u8, allocator: Allocator) void {
    const relative = blk: {
        if (std.mem.startsWith(u8, target, "/gui/")) break :blk target[1..];
        if (std.mem.eql(u8, target, "/") or target.len == 0) break :blk "gui/index.html";
        break :blk "gui/index.html";
    };

    const contents = std.fs.cwd().readFileAlloc(allocator, relative, std.math.maxInt(usize)) catch {
        const body = "not found";
        sendHttpResponse(stream, "HTTP/1.1 404 Not Found\r\n", "Content-Type: text/plain\r\n", body) catch {};
        return;
    };
    defer allocator.free(contents);

    const header = std.fmt.allocPrint(allocator, "Content-Type: {s}\r\n", .{staticContentType(relative)}) catch {
        allocator.free(contents);
        return;
    };
    defer allocator.free(header);
    sendHttpResponse(stream, "HTTP/1.1 200 OK\r\n", header, contents) catch {};
}

fn handleWebsocket(app: *AppState, stream: anytype, allocator: Allocator) !void {
    defer stream.close();
    var reader = stream.reader();
    const header_bytes = try reader.readUntilDelimiterOrEofAlloc(allocator, "\r\n\r\n", 16 * 1024);
    defer allocator.free(header_bytes);

    const request_line_end = std.mem.indexOf(u8, header_bytes, "\r\n") orelse return error.InvalidHandshake;
    const request_line = header_bytes[0..request_line_end];
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidHandshake;
    const path = parts.next() orelse return error.InvalidHandshake;
    if (!std.mem.eql(u8, method, "GET")) return error.InvalidHandshake;
    if (!std.mem.eql(u8, path, "/ws")) {
        serveStatic(stream, path, allocator);
        return;
    }

    try websocketHandshake(stream, header_bytes);

    var outbound_queue = MessageQueue.init(allocator);
    defer outbound_queue.deinit();

    var sender = try std.Thread.spawn(.{}, outboundLoop, .{ &outbound_queue, stream, allocator });
    defer {
        outbound_queue.stop();
        sender.join();
    }

    var ws_reader = stream.reader();
    var ws_writer = stream.writer();

    var participant_id = try generateRandomString(allocator, 20);
    var room_id_buf = try generateRandomString(allocator, 6);
    var room_id: []const u8 = room_id_buf;

    var room: *Room = undefined;
    {
        app.rooms_mutex.lock();
        defer app.rooms_mutex.unlock();
        var new_room = try app.allocator.create(Room);
        new_room.* = try Room.init(app.allocator, room_id);
        try app.rooms.put(try app.allocator.dupe(u8, room_id), new_room);
        room = new_room;
    }
    allocator.free(room_id_buf);
    room_id = room.id;

    // reader thread loop
    var running = true;
    while (running) {
        const payload_opt = readFrame(ws_reader, allocator) catch |err| {
            std.log.err("websocket read failed: {s}", .{@errorName(err)});
            break;
        };
        if (payload_opt == null) break;
        const payload = payload_opt.?;
        defer allocator.free(payload);
        const msg = parseClientMessage(allocator, payload) catch {
            continue;
        };
        switch (msg) {
            .newroom => |data| {
                if (data.socket_id) |sid| {
                    allocator.free(participant_id);
                    participant_id = try allocator.dupe(u8, sid);
                }
                room_id = room.id;
                room.join(participant_id, &outbound_queue) catch |err| {
                    if (err == error.RoomIsFull) {
                        const crowded = ServerMessage{ .room_is_crowded = .{ .message = try allocator.dupe(u8, "Room is full (max 4 participants).") } };
                        const payload_out = try serializeServerMessage(allocator, crowded);
                        defer allocator.free(payload_out);
                        try writeFrame(ws_writer, payload_out);
                    }
                };
                const view = try room.render(participant_id);
                const message = ServerMessage{ .got_room = view };
                const payload_out = try serializeServerMessage(allocator, message);
                defer allocator.free(payload_out);
                message.deinit(allocator);
                try writeFrame(ws_writer, payload_out);
                room.notifyParticipants(participant_id);
            },
            .fetchRoom => |data| {
                if (data.socket_id) |sid| {
                    allocator.free(participant_id);
                    participant_id = try allocator.dupe(u8, sid);
                }
                room_id = data.id;
                app.rooms_mutex.lock();
                var room_ptr = app.rooms.get(room_id);
                if (room_ptr == null) {
                    var created = try app.allocator.create(Room);
                    created.* = try Room.init(app.allocator, room_id);
                    try app.rooms.put(try app.allocator.dupe(u8, room_id), created);
                    room_ptr = created;
                }
                room = room_ptr.?;
                app.rooms_mutex.unlock();
                room.join(participant_id, &outbound_queue) catch |err| {
                    if (err == error.RoomIsFull) {
                        const crowded = ServerMessage{ .room_is_crowded = .{ .message = try allocator.dupe(u8, "Room is full (max 4 participants).") } };
                        const payload_out = try serializeServerMessage(allocator, crowded);
                        defer allocator.free(payload_out);
                        try writeFrame(ws_writer, payload_out);
                    }
                };
                const view = try room.render(participant_id);
                const message = ServerMessage{ .got_room = view };
                const payload_out = try serializeServerMessage(allocator, message);
                defer allocator.free(payload_out);
                message.deinit(allocator);
                try writeFrame(ws_writer, payload_out);
                room.notifyParticipants(participant_id);
            },
            .keyPress => |data| {
                applyKeyPress(room, participant_id, data.key, data.cursor_pos);
            },
        }
    }

    room.leave(participant_id);
    room.notifyParticipants(participant_id);
    allocator.free(participant_id);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) std.log.err("memory leaked", .{});
    }
    const allocator = gpa.allocator();

    var app = AppState.init(allocator);
    defer app.deinit();

    var server = std.net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    const address = try std.net.Address.resolveIp("0.0.0.0", 8090);
    try server.listen(address);
    std.log.info("Server running on http://0.0.0.0:8090", .{});

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        std.Thread.spawn(.{}, handleWebsocket, .{ &app, conn.stream, allocator }) catch |err| {
            std.log.err("failed to spawn thread: {s}", .{@errorName(err)});
            conn.stream.close();
        };
    }
}
