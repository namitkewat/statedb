const std = @import("std");
const clap = @import("clap");
const lib = @import("lib.zig");

const fmt = std.fmt;
const io = std.io;
const net = std.net;
const mem = std.mem;
const Allocator = mem.Allocator;

const HashMap = std.StringHashMap(Value);
const ExpirationMap = std.StringHashMap(u64);
const ArrayList = std.ArrayList;

const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: ArrayList(Value),
    hash: *HashMap,
    zset: *std.StringHashMap(f64),
};

// Holds information about the connected client, set via `CLIENT SETINFO`.
const ClientInfo = struct {
    addr: ?[]u8 = null,
    lib_name: ?[]u8 = null,
    lib_ver: ?[]u8 = null,

    // Frees any allocated memory within the struct.
    pub fn deinit(self: *ClientInfo, alloc: Allocator) void {
        if (self.addr) |a| alloc.free(a);
        if (self.lib_name) |name| alloc.free(name);
        if (self.lib_ver) |ver| alloc.free(ver);
        self.* = .{}; // Reset the struct to its default state.
    }

    // Custom formatter for logging.
    pub fn format(self: ClientInfo, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        if (self.addr) |a| {
            try writer.print("{s}", .{a});
        } else {
            try writer.print("unknown-addr", .{});
        }
        if (self.lib_name) |name| {
            try writer.print(" ({s}", .{name});
            if (self.lib_ver) |ver| {
                try writer.print("-{s}", .{ver});
            }
            try writer.print(")", .{});
        }
    }
};

// Represents the shared state of the server, protected by a mutex
const SharedState = struct {
    mutex: std.Thread.Mutex,
    db: HashMap,
    expirations: ExpirationMap,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SharedState {
        return .{
            .mutex = .{},
            .db = HashMap.init(allocator),
            .expirations = ExpirationMap.init(allocator),
            .allocator = allocator,
        };
    }

    // Deinitializes the shared state, ensuring all allocated memory is freed.
    pub fn deinit(self: *SharedState) void {
        // Helper function to free contents of a Value
        const T = struct {
            fn freeValueContents(alloc: Allocator, v: Value) void {
                switch (v) {
                    .string => |s| alloc.free(s),
                    .list => |l| {
                        for (l.items) |item| freeValueContents(alloc, item);
                        l.deinit();
                    },
                    .hash => |h| {
                        var it = h.iterator();
                        while (it.next()) |entry| {
                            alloc.free(entry.key_ptr.*);
                            freeValueContents(alloc, entry.value_ptr.*);
                        }
                        h.deinit();
                        alloc.destroy(h);
                    },
                    .zset => |zs| {
                        var it = zs.iterator();
                        while (it.next()) |entry| {
                            alloc.free(entry.key_ptr.*);
                        }
                        zs.deinit();
                        alloc.destroy(zs);
                    },
                    .integer => {},
                }
            }
        };

        // Deinitialize all values within the database
        var it = self.db.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            T.freeValueContents(self.allocator, entry.value_ptr.*);
        }
        self.db.deinit();
        self.expirations.deinit();
    }
};

// A simple reader to consume bytes from the input buffer
const BufferReader = struct {
    buffer: []const u8,
    cursor: usize = 0,

    fn readByte(self: *BufferReader) ?u8 {
        if (self.cursor >= self.buffer.len) return null;
        const byte = self.buffer[self.cursor];
        self.cursor += 1;
        return byte;
    }

    fn readUntilCrLf(self: *BufferReader) ?[]const u8 {
        const start = self.cursor;
        while (self.cursor + 1 < self.buffer.len) {
            if (self.buffer[self.cursor] == '\r' and self.buffer[self.cursor + 1] == '\n') {
                const line = self.buffer[start..self.cursor];
                self.cursor += 2; // Skip over \r\n
                return line;
            }
            self.cursor += 1;
        }
        // If we reach here, we didn't find a CRLF. Reset cursor for next attempt.
        self.cursor = start;
        return null;
    }

    fn readN(self: *BufferReader, n: usize) ?[]const u8 {
        if (self.cursor + n > self.buffer.len) return null;
        const bytes = self.buffer[self.cursor .. self.cursor + n];
        self.cursor += n;
        return bytes;
    }
};

fn setupServer(name: []const u8, port: u16) !std.net.Server {
    const stdAddress = std.net.Address;
    const address = try stdAddress.parseIp(name, port);
    const options = stdAddress.ListenOptions{ .reuse_address = true };
    return try stdAddress.listen(address, options);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-a, --address <STR>   An optional parameter, to set server address; default is 127.0.0.1
        \\-p, --port <INT>      An optional parameter, to set port number; default is 8080
        \\
    );
    const parsers = comptime .{
        .STR = clap.parsers.string,
        .INT = clap.parsers.int(usize, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa_allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("--help\n", .{});
        std.process.exit(0);
    }
    var port: u16 = 8080;
    if (res.args.port) |p| {
        port = @intCast(p);
    }

    var address: []const u8 = "127.0.0.1";
    if (res.args.address) |a| {
        address = a;
    }

    var shared_state = SharedState.init(gpa_allocator);
    defer shared_state.deinit();

    var listener = try setupServer(address, port);
    defer listener.deinit();

    // Now, all looks good hence we can allocate resources
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // const arena_allocator = arena.allocator();

    // var db = HashMap.init(arena_allocator);
    // defer db.deinit();
    // var expirations = ExpirationMap.init(arena_allocator);
    // defer expirations.deinit();

    std.debug.print("Sever listening on {s}:{d}\n", .{ address, port });
    while (true) {
        const client_connection = try listener.accept();
        const t = std.Thread.spawn(.{}, handleClient, .{ client_connection, &shared_state }) catch |err| {
            std.log.err("Failed to spawn thread: {}", .{err});
            return;
        };
        t.detach();
    }

    std.process.exit(0);
}

fn handleClient(
    client_connection: net.Server.Connection,
    state: *SharedState,
) !void {
    defer client_connection.stream.close();
    // _ = state;

    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer thread_arena.deinit();
    const allocator = thread_arena.allocator();

    var client_info = ClientInfo{};
    defer client_info.deinit(allocator);

    client_info.addr = std.fmt.allocPrint(allocator, "({any})", .{client_connection.address.in}) catch |err| {
        std.log.info("Failed to format client address: {any}", .{err});
        return;
    };
    // const client_addr_str = try std.fmt.allocPrint(allocator, "({any})", .{client_connection.address.in});
    // client_info.addr = client_addr_str;
    // defer allocator.free(client_addr_str);

    // std.log.info("{s} - Client connected\n", .{client_info});

    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = client_connection.stream.read(buffer[0..]) catch |err| {
            // const bytes_read = client_stream.read(&buffer) catch |err| {
            if (err == error.ConnectionResetByPeer or err == error.BrokenPipe or err == error.ConnectionResetByPeer) {
                // std.log.info("{s} - Client disconnected\n", .{client_info});
            } else {
                std.log.err("{s} - Error reading from client: {any}", .{ client_info, err });
            }
            return;
        };

        if (bytes_read == 0) {
            // std.log.info("{s} - Client closed connection\n", .{client_info});
            return;
        }

        const data: []const u8 = buffer[0..bytes_read];
        // std.log.info("{s} - Client Raw input: '{any}'\n", .{ client_info, data }); // Add this for debugging

        const result = lib.parseCommand(allocator, data);
        if (result) |cmd| {
            defer cmd.deinit(); // IMPORTANT: Ensure args slice is freed.

            // try printCommandDetails(allocator, cmd);

            // const response = try allocator.dupe(u8, cmd.name);
            // defer allocator.free(response);

            const response = handleCommand(allocator, cmd, state, &client_info) catch |err| {
                // This catch is for unexpected allocation errors during response encoding
                std.log.err("{s} - Failed to encode response for client: {any}", .{ client_info, err });
                continue;
            };

            // const response = try arena_allocator.dupe(u8, cmd.name);
            defer allocator.free(response);
            _ = try client_connection.stream.writeAll(response);

            // Continue processing next commands
            // continue;
        } else |err| {
            std.log.warn("{s} - Parse error from: {any}", .{ client_info, err });
            const error_response = Resp.encodeError("ERR invalid command format", allocator) catch continue;
            defer allocator.free(error_response);

            _ = client_connection.stream.writeAll(error_response) catch |e| {
                std.log.warn("{s} - Failed to write parse error to client: {any}", .{ client_info, e });
                return;
            };

            // Continue processing next commands
            continue; // Note This countinue is required, otherwise if you return then server will stop sending response
        }
    }
}

fn handleCommand(allocator: std.mem.Allocator, cmd: lib.Command, state: *SharedState, client_info: *ClientInfo) ![]const u8 {
    const T = struct {
        fn freeValueContents(alloc: Allocator, v: Value) void {
            switch (v) {
                .string => |s| alloc.free(s),
                .list => |l| {
                    for (l.items) |item| freeValueContents(alloc, item);
                    l.deinit();
                },
                .hash => |h| {
                    var it = h.iterator();
                    while (it.next()) |entry| {
                        alloc.free(entry.key_ptr.*);
                        freeValueContents(alloc, entry.value_ptr.*);
                    }
                    h.deinit();
                    alloc.destroy(h);
                },
                .zset => |zs| {
                    var it = zs.iterator();
                    while (it.next()) |entry| {
                        alloc.free(entry.key_ptr.*);
                    }
                    zs.deinit();
                    alloc.destroy(zs);
                },
                .integer => {},
            }
        }
        fn encodeArray(items: []const []const u8) ![]u8 {
            return Resp.encodeArray(items, allocator);
        }

        fn encodeError(msg: []const u8) ![]u8 {
            return Resp.encodeError(msg, allocator);
        }

        fn encodeErrorFmt(comptime format: []const u8, args: anytype) ![]u8 {
            return Resp.encodeErrorFmt(allocator, format, args);
        }
    };

    // Commands that don't access shared state are handled first, without locking.
    if (std.ascii.eqlIgnoreCase(cmd.name, "PING")) {
        const parsed = cmd.asPing() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'ping' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        if (parsed.message) |msg| {
            return Resp.encodeString(msg, allocator);
        } else {
            return Resp.encodeString("PONG", allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "ECHO")) {
        const parsed = cmd.asEcho() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'echo' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        return Resp.encodeString(parsed.message, allocator);
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "CLIENT")) {
        const parsed = cmd.asClient() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'client' command", .{}),
                error.InvalidCommandFormat => Resp.encodeErrorFmt(allocator, "ERR Syntax error, try CLIENT HELP", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        return switch (parsed) {
            .setinfo => |setinfo_cmd| {
                if (std.ascii.eqlIgnoreCase(setinfo_cmd.key, "LIB-NAME")) {
                    if (client_info.lib_name) |old_name| allocator.free(old_name);
                    client_info.lib_name = try allocator.dupe(u8, setinfo_cmd.value);
                } else if (std.ascii.eqlIgnoreCase(setinfo_cmd.key, "LIB-VER")) {
                    if (client_info.lib_ver) |old_ver| allocator.free(old_ver);
                    client_info.lib_ver = try allocator.dupe(u8, setinfo_cmd.value);
                }
                return Resp.encodeSimpleString("OK", allocator);
            },
        };
    }

    state.mutex.lock();

    // const start_time = std.time.nanoTimestamp();

    const cmd_upper_name = try lib.toUpperAlloc(allocator, cmd.name);
    defer allocator.free(cmd_upper_name);
    defer {
        // const end_time = std.time.nanoTimestamp();
        // const duration_ns = end_time - start_time;
        // std.log.info("{s} - Command '{s}' took {d} ns", .{ client_info, cmd_upper_name, duration_ns });
        state.mutex.unlock();
    }

    if (std.ascii.eqlIgnoreCase(cmd.name, "SET")) {
        const parsed = cmd.asSet() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'set' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        const entry = try state.db.getOrPut(parsed.key);
        const new_value = Value{ .string = try state.allocator.dupe(u8, parsed.value) };

        if (entry.found_existing) {
            T.freeValueContents(state.allocator, entry.value_ptr.*); // Free old value
        } else {
            entry.key_ptr.* = try state.allocator.dupe(u8, parsed.key); // Copy new key
        }
        entry.value_ptr.* = new_value;
        return Resp.encodeSimpleString("OK", allocator);
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "GET")) {
        const parsed = cmd.asGet() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'get' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };

        if (state.db.get(parsed.key)) |value| {
            return switch (value) {
                .string => |s| Resp.encodeString(s, allocator),
                .integer => |s| Resp.encodeInteger(s, allocator),
                else => Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
        } else {
            return Resp.encodeNull(allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "GETDEL")) {
        const parsed = cmd.asGetDel() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'getdel' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };

        if (state.db.get(parsed.key)) |value| {
            return switch (value) {
                .string => |s| {
                    defer {
                        if (state.db.fetchRemove(parsed.key)) |removed| {
                            state.allocator.free(removed.key);
                            T.freeValueContents(state.allocator, removed.value);
                            _ = state.expirations.remove(parsed.key);
                        }
                    }
                    return Resp.encodeString(s, allocator);
                },
                .integer => |s| {
                    defer {
                        if (state.db.fetchRemove(parsed.key)) |removed| {
                            state.allocator.free(removed.key);
                            T.freeValueContents(state.allocator, removed.value);
                            _ = state.expirations.remove(parsed.key);
                        }
                    }
                    return Resp.encodeInteger(s, allocator);
                },
                else => Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
        } else {
            return Resp.encodeNull(allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "INCR")) {
        const parsed = cmd.asIncr() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'incr' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        const entry = try state.db.getOrPut(parsed.key);

        if (entry.found_existing) {
            const new_val = switch (entry.value_ptr.*) {
                .integer => |*val| blk: {
                    val.* += 1;
                    break :blk val.*;
                },
                .string => |s| blk: {
                    const current_val = std.fmt.parseInt(i64, s, 10) catch
                        return Resp.encodeError("ERR value is not an integer or out of range", allocator);
                    const new_val_int: i64 = current_val + 1;
                    state.allocator.free(s); // free old string
                    entry.value_ptr.* = Value{ .integer = new_val_int };
                    break :blk new_val_int;
                },
                else => return Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
            return Resp.encodeInteger(new_val, allocator);
        } else {
            // Key did not exist, create it with value 1
            entry.key_ptr.* = try state.allocator.dupe(u8, parsed.key);
            entry.value_ptr.* = Value{ .integer = 1 };
            return Resp.encodeInteger(1, allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "INCRBY")) {
        const parsed = cmd.asIncrBy() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'incrby' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        const entry = try state.db.getOrPut(parsed.key);
        const amount = parsed.amount;

        if (entry.found_existing) {
            const new_val = switch (entry.value_ptr.*) {
                .integer => |*val| blk: {
                    val.* += amount;
                    break :blk val.*;
                },
                .string => |s| blk: {
                    const current_val = std.fmt.parseInt(i64, s, 10) catch
                        return Resp.encodeError("ERR value is not an integer or out of range", allocator);
                    const new_val_int: i64 = current_val + amount;
                    state.allocator.free(s); // free old string
                    entry.value_ptr.* = Value{ .integer = new_val_int };
                    break :blk new_val_int;
                },
                else => return Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
            return Resp.encodeInteger(new_val, allocator);
        } else {
            // Key did not exist, create it with value 1
            entry.key_ptr.* = try state.allocator.dupe(u8, parsed.key);
            entry.value_ptr.* = Value{ .integer = amount };
            return Resp.encodeInteger(amount, allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "DECR")) {
        const parsed = cmd.asDecr() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'decr' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        const entry = try state.db.getOrPut(parsed.key);

        if (entry.found_existing) {
            const new_val = switch (entry.value_ptr.*) {
                .integer => |*val| blk: {
                    val.* -= 1;
                    break :blk val.*;
                },
                .string => |s| blk: {
                    const current_val = std.fmt.parseInt(i64, s, 10) catch
                        return Resp.encodeError("ERR value is not an integer or out of range", allocator);
                    const new_val_int: i64 = current_val - 1;
                    state.allocator.free(s); // free old string
                    entry.value_ptr.* = Value{ .integer = new_val_int };
                    break :blk new_val_int;
                },
                else => return Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
            return Resp.encodeInteger(new_val, allocator);
        } else {
            // Key did not exist, create it with value -1
            entry.key_ptr.* = try state.allocator.dupe(u8, parsed.key);
            entry.value_ptr.* = Value{ .integer = -1 };
            return Resp.encodeInteger(-1, allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "DECRBY")) {
        const parsed = cmd.asDecrBy() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'decrby' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        const entry = try state.db.getOrPut(parsed.key);
        const amount = parsed.amount;

        if (entry.found_existing) {
            const new_val = switch (entry.value_ptr.*) {
                .integer => |*val| blk: {
                    val.* -= amount;
                    break :blk val.*;
                },
                .string => |s| blk: {
                    const current_val = std.fmt.parseInt(i64, s, 10) catch
                        return Resp.encodeError("ERR value is not an integer or out of range", allocator);
                    const new_val_int: i64 = current_val - amount;
                    state.allocator.free(s); // free old string
                    entry.value_ptr.* = Value{ .integer = new_val_int };
                    break :blk new_val_int;
                },
                else => return Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
            return Resp.encodeInteger(new_val, allocator);
        } else {
            // Key did not exist, create it with value 1
            entry.key_ptr.* = try state.allocator.dupe(u8, parsed.key);
            entry.value_ptr.* = Value{ .integer = -amount };
            return Resp.encodeInteger(-amount, allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "DEL")) {
        const parsed = cmd.asDel() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'del' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        var deleted_count: i64 = 0;
        for (parsed.keys) |key| {
            if (state.db.fetchRemove(key)) |removed| {
                state.allocator.free(removed.key);
                T.freeValueContents(state.allocator, removed.value);
                _ = state.expirations.remove(key);
                deleted_count += 1;
            }
        }
        return Resp.encodeInteger(deleted_count, allocator);
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "EXISTS")) {
        const parsed = cmd.asExists() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'exists' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        var found_count: i64 = 0;
        for (parsed.keys) |key| {
            if (state.db.contains(key)) {
                found_count += 1;
            }
        }
        return Resp.encodeInteger(found_count, allocator);
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "FLUSHDB")) {
        _ = cmd.asFlushDb() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'flushdb' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        var it = state.db.iterator();
        while (it.next()) |entry| {
            state.allocator.free(entry.key_ptr.*);
            T.freeValueContents(state.allocator, entry.value_ptr.*);
        }
        state.db.clearRetainingCapacity();
        state.expirations.clearRetainingCapacity();
        return Resp.encodeSimpleString("OK", allocator);
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "TYPE")) {
        const parsed = cmd.asType() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'type' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        if (state.db.get(parsed.key)) |value| {
            const type_name = switch (value) {
                .string => "string",
                .integer => "integer",
                .list => "list",
                .hash => "hash",
                .zset => "zset",
            };
            return Resp.encodeSimpleString(type_name, allocator);
        } else {
            return Resp.encodeSimpleString("none", allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "HSET")) {
        const parsed = cmd.asHSet() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'hset' command", .{}),
                error.InvalidArgumentType => Resp.encodeError("ERR value is not a valid float", allocator),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        defer allocator.free(parsed.pairs);

        const entry = try state.db.getOrPut(parsed.key);
        var added_count: i64 = 0;

        if (!entry.found_existing) {
            entry.key_ptr.* = try state.allocator.dupe(u8, parsed.key);
            const new_hash = try state.allocator.create(HashMap);
            new_hash.* = HashMap.init(state.allocator);
            entry.value_ptr.* = Value{ .hash = new_hash };
        }

        const h = switch (entry.value_ptr.*) {
            .hash => |hash_ptr| hash_ptr,
            else => return Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
        };

        for (parsed.pairs) |pair| {
            const field_entry = try h.getOrPut(pair.field);
            const new_value = Value{ .string = try state.allocator.dupe(u8, pair.value) };
            if (field_entry.found_existing) {
                T.freeValueContents(state.allocator, field_entry.value_ptr.*);
            } else {
                field_entry.key_ptr.* = try state.allocator.dupe(u8, pair.field);
                added_count += 1;
            }
            field_entry.value_ptr.* = new_value;
        }
        return Resp.encodeInteger(added_count, allocator);
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "HGET")) {
        const parsed = cmd.asHGet() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'hget' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        if (state.db.get(parsed.key)) |value| {
            return switch (value) {
                .hash => |h| {
                    if (h.get(parsed.field)) |field_val| {
                        return switch (field_val) {
                            .string => |s| Resp.encodeString(s, allocator),
                            else => Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
                        };
                    } else {
                        return Resp.encodeNull(allocator);
                    }
                },
                else => Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
        } else {
            return Resp.encodeNull(allocator);
        }
    } else if (std.ascii.eqlIgnoreCase(cmd.name, "HGETALL")) {
        const parsed = cmd.asHGetAll() catch |e| {
            return switch (e) {
                error.WrongNumberOfArguments => Resp.encodeErrorFmt(allocator, "ERR wrong number of arguments for 'hgetall' command", .{}),
                else => Resp.encodeError("ERR syntax error", allocator),
            };
        };
        if (state.db.get(parsed.key)) |value| {
            return switch (value) {
                .hash => |h| {
                    var items = ArrayList([]const u8).init(allocator);
                    defer items.deinit();
                    var it = h.iterator();
                    while (it.next()) |entry| {
                        try items.append(entry.key_ptr.*);
                        try items.append(entry.value_ptr.string);
                    }
                    return Resp.encodeArray(items.items, allocator);
                },
                else => Resp.encodeError("WRONGTYPE Operation against a key holding the wrong kind of value", allocator),
            };
        } else {
            return Resp.encodeArray(&.{}, allocator);
        }
    } else {
        return Resp.encodeErrorFmt(allocator, "ERR unknown command `{s}`", .{cmd.name});
    }
}

const Resp = struct {
    pub fn encodeSimpleString(s: []const u8, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "+{s}\r\n", .{s});
    }

    pub fn encodeString(s: []const u8, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n", .{ s.len, s });
    }

    pub fn encodeInteger(i: i64, allocator: mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, ":{d}\r\n", .{i});
    }

    pub fn encodeNull(allocator: mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "$-1\r\n");
    }

    pub fn encodeError(msg: []const u8, allocator: Allocator) ![]u8 {
        return try encodeErrorFmt(allocator, "{s}", .{msg});
    }

    pub fn encodeErrorFmt(allocator: Allocator, comptime format: []const u8, args: anytype) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        try list.writer().print("-" ++ format ++ "\r\n", args);
        return list.toOwnedSlice();
    }

    pub fn encodeArray(items: []const []const u8, allocator: Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("*{d}\r\n", .{items.len});
        for (items) |item| {
            try writer.print("${d}\r\n{s}\r\n", .{ item.len, item });
        }
        return buf.toOwnedSlice();
    }
};

const testing = std.testing;
const test_allocator = testing.allocator;

// Helper to create Command and validate fields
fn expectCommand(input: []const u8, expected_name: []const u8, expected_args: []const []const u8) !void {
    var cmd = try lib.parseCommand(test_allocator, input);
    defer cmd.deinit();

    try testing.expectEqualStrings(expected_name, cmd.name);
    try testing.expectEqual(expected_args.len, cmd.args.len);

    for (expected_args, cmd.args) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
}

test "String commands: GET" {
    // RESP format
    try expectCommand("*2\r\n$3\r\nGET\r\n$4\r\nname\r\n", "GET", &[_][]const u8{"name"});
    // Inline format
    try expectCommand("GET name", "GET", &[_][]const u8{"name"});
}

test "String commands: SET" {
    // RESP format
    try expectCommand("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nJoe\r\n", "SET", &[_][]const u8{ "name", "Joe" });
    // Inline with quotes
    try expectCommand("SET name Joe", "SET", &[_][]const u8{ "name", "Joe" });
}

test "String commands: INCR/DECR" {
    // RESP INCR
    try expectCommand("*2\r\n$4\r\nINCR\r\n$7\r\ncounter\r\n", "INCR", &[_][]const u8{"counter"});
    // Inline DECR
    try expectCommand("DECR counter", "DECR", &[_][]const u8{"counter"});
}

test "String commands: INCRBY/DECRBY" {
    // RESP INCRBY
    try expectCommand("*3\r\n$6\r\nINCRBY\r\n$7\r\ncounter\r\n$2\r\n10\r\n", "INCRBY", &[_][]const u8{ "counter", "10" });
    // Inline DECRBY
    try expectCommand("DECRBY counter 5", "DECRBY", &[_][]const u8{ "counter", "5" });
}

// test "String commands: GETDEL/GETSET" {
//     // RESP GETDEL
//     try expectCommand("*2\r\n$6\r\nGETDEL\r\n$3\r\nkey\r\n", "GETDEL", &[_][]const u8{"key"});
//     // Inline GETSET
//     try expectCommand("GETSET key value", "GETSET", &[_][]const u8{ "key", "value" });
// }

test "String commands: GETDEL" {
    // RESP GETDEL
    try expectCommand("*2\r\n$6\r\nGETDEL\r\n$3\r\nkey\r\n", "GETDEL", &[_][]const u8{"key"});
    // Inline GETDEL
    try expectCommand("GETDEL key", "GETDEL", &[_][]const u8{"key"});
}

test "Key commands: DEL" {
    // RESP format (multiple keys)
    try expectCommand("*3\r\n$3\r\nDEL\r\n$3\r\nkey\r\n$6\r\nkey123\r\n", "DEL", &[_][]const u8{ "key", "key123" });
    // Inline format
    try expectCommand("DEL key1 key2", "DEL", &[_][]const u8{ "key1", "key2" });
}

test "Key commands: EXISTS" {
    // RESP format
    try expectCommand("*2\r\n$6\r\nEXISTS\r\n$3\r\nkey\r\n", "EXISTS", &[_][]const u8{"key"});
    // Inline with multiple keys
    try expectCommand("EXISTS key1 key2", "EXISTS", &[_][]const u8{ "key1", "key2" });
}

// test "Key commands: EXPIRE family" {
//     // RESP EXPIRE
//     try expectCommand("*3\r\n$6\r\nEXPIRE\r\n$3\r\nkey\r\n$3\r\n300\r\n", "EXPIRE", &[_][]const u8{ "key", "300" });
//     // Inline EXPIREAT
//     try expectCommand("EXPIREAT key 1719500000", "EXPIREAT", &[_][]const u8{ "key", "1719500000" });
//     // RESP EXPIRETIME
//     try expectCommand("*2\r\n$11\r\nEXPIRETIME\r\n$3\r\nkey\r\n", "EXPIRETIME", &[_][]const u8{"key"});
// }

test "Key commands: FLUSHDB/TYPE" {
    // RESP FLUSHDB
    try expectCommand("*1\r\n$7\r\nFLUSHDB\r\n", "FLUSHDB", &.{});
    // Inline TYPE
    try expectCommand("TYPE mykey", "TYPE", &[_][]const u8{"mykey"});
}

// test "Key commands: FLUSHDB/KEYS/TTL/TYPE" {
//     // RESP FLUSHDB
//     try expectCommand("*1\r\n$7\r\nFLUSHDB\r\n", "FLUSHDB", &.{});
//     // Inline KEYS
//     try expectCommand("KEYS user:*", "KEYS", &[_][]const u8{"user:*"});
//     // RESP TTL
//     try expectCommand("*2\r\n$3\r\nTTL\r\n$3\r\nkey\r\n", "TTL", &[_][]const u8{"key"});
//     // Inline TYPE
//     try expectCommand("TYPE mykey", "TYPE", &[_][]const u8{"mykey"});
// }

test "Hash commands: HSET/HGET/HGETALL" {
    // RESP HSET (multiple fields)
    try expectCommand("*6\r\n$4\r\nHSET\r\n$6\r\nmyhash\r\n$5\r\nfield\r\n$5\r\nvalue\r\n$6\r\nfield2\r\n$6\r\nvalue2\r\n", "HSET", &[_][]const u8{ "myhash", "field", "value", "field2", "value2" });
    // Inline HGET
    try expectCommand("HGET myhash field", "HGET", &[_][]const u8{ "myhash", "field" });
    // RESP HGETALL
    try expectCommand("*2\r\n$7\r\nHGETALL\r\n$6\r\nmyhash\r\n", "HGETALL", &[_][]const u8{"myhash"});
}

// test "Sorted Set commands: ZADD/ZCARD/ZCOUNT" {
//     // RESP ZADD (multiple members)
//     try expectCommand("*7\r\n$4\r\nZADD\r\n$3\r\nkey\r\n$3\r\n100\r\n$6\r\nmember\r\n$3\r\n200\r\n$8\r\nmember2\r\n$3\r\n300\r\n$8\r\nmember3\r\n", "ZADD", &[_][]const u8{ "key", "100", "member", "200", "member2", "300", "member3" });
//     // Inline ZCARD
//     try expectCommand("ZCARD myset", "ZCARD", &[_][]const u8{"myset"});
//     // RESP ZCOUNT
//     try expectCommand("*4\r\n$6\r\nZCOUNT\r\n$5\r\nzset1\r\n$1\r\n0\r\n$3\r\n100\r\n", "ZCOUNT", &[_][]const u8{ "zset1", "0", "100" });
// }

// test "Sorted Set commands: ZPOPMAX/ZPOPMIN/ZRANGE" {
//     // RESP ZPOPMAX
//     try expectCommand("*3\r\n$7\r\nZPOPMAX\r\n$4\r\nzset\r\n$2\r\n10\r\n", "ZPOPMAX", &[_][]const u8{ "zset", "10" });
//     // Inline ZPOPMIN
//     try expectCommand("ZPOPMIN zset 5", "ZPOPMIN", &[_][]const u8{ "zset", "5" });
//     // RESP ZRANGE with scores
//     try expectCommand("*5\r\n$6\r\nZRANGE\r\n$4\r\nzset\r\n$1\r\n0\r\n$2\r\n-1\r\n$10\r\nWITHSCORES\r\n", "ZRANGE", &[_][]const u8{ "zset", "0", "-1", "WITHSCORES" });
// }

// test "Sorted Set commands: ZRANK/ZREM" {
//     // RESP ZRANK
//     try expectCommand("*3\r\n$5\r\nZRANK\r\n$4\r\nzset\r\n$6\r\nmember\r\n", "ZRANK", &[_][]const u8{ "zset", "member" });
//     // Inline ZREM with multiple members
//     try expectCommand("ZREM zset member1 member2", "ZREM", &[_][]const u8{ "zset", "member1", "member2" });
// }

test "Connection commands: PING/ECHO" {
    // RESP PING without message
    try expectCommand("*1\r\n$4\r\nPING\r\n", "PING", &.{});
    // RESP PING with message
    try expectCommand("*2\r\n$4\r\nPING\r\n$5\r\nhello\r\n", "PING", &[_][]const u8{"hello"});
    // Inline ECHO
    try expectCommand("ECHO \"Hello World\"", "ECHO", &[_][]const u8{"Hello World"});
}

test "Client commands: SETINFO" {
    // RESP format (redis-py style)
    try expectCommand("*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$8\r\nredis-py\r\n", "CLIENT", &[_][]const u8{ "SETINFO", "LIB-NAME", "redis-py" });
    // Inline format
    try expectCommand("CLIENT SETINFO LIB-VER 6.2.0", "CLIENT", &[_][]const u8{ "SETINFO", "LIB-VER", "6.2.0" });
}

test "Edge cases and errors" {
    // Empty command
    try testing.expectError(lib.ParseError.EmptyCommand, lib.parseCommand(test_allocator, ""));

    // Incomplete RESP
    try testing.expectError(lib.ParseError.UnexpectedEnd, lib.parseCommand(test_allocator, "*2\r\n$3\r\nGET"));

    // Invalid FORMAT
    try testing.expectError(lib.ParseError.InvalidInteger, lib.parseCommand(test_allocator, "*abc\r\n"));

    // Missing CRLF
    try testing.expectError(lib.ParseError.ExpectedCRLF, lib.parseCommand(test_allocator, "*1"));

    // Unclosed quote
    try testing.expectError(lib.ParseError.UnclosedQuote, lib.parseCommand(test_allocator, "SET name \"value"));

    // Invalid bulk string header
    try testing.expectError(lib.ParseError.InvalidFormat, lib.parseCommand(test_allocator, "*1\r\nabc\r\n"));

    // Negative element count
    try testing.expectError(lib.ParseError.InvalidInteger, lib.parseCommand(test_allocator, "*-1\r\n"));
}

test "Mixed quoting and whitespace" {
    // Mixed quotes in inline command
    try expectCommand("SET user John", "SET", &[_][]const u8{ "user", "John" });

    // Extra whitespace
    try expectCommand("  SET   key   value  ", "SET", &[_][]const u8{ "key", "value" });
}

test "Real-world redis-py commands" {
    // LIB-NAME command
    try expectCommand("*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$8\r\nredis-py\r\n", "CLIENT", &[_][]const u8{ "SETINFO", "LIB-NAME", "redis-py" });

    // LIB-VER command
    try expectCommand("*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$7\r\nLIB-VER\r\n$5\r\n6.2.0\r\n", "CLIENT", &[_][]const u8{ "SETINFO", "LIB-VER", "6.2.0" });

    // SET command after metadata
    try expectCommand("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nJoe\r\n", "SET", &[_][]const u8{ "name", "Joe" });
}
