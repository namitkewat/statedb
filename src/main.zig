const std = @import("std");
const clap = @import("clap");

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

//==============================================================================
//  Command-Specific Structs
//==============================================================================

// --- String Commands ---
pub const GetCommand = struct { key: []const u8 };
pub const SetCommand = struct { key: []const u8, value: []const u8 };
pub const IncrCommand = struct { key: []const u8 };
pub const DecrCommand = struct { key: []const u8 };
pub const IncrByCommand = struct { key: []const u8, amount: i64 };
pub const DecrByCommand = struct { key: []const u8, amount: i64 };
pub const GetDelCommand = struct { key: []const u8 };
pub const GetSetCommand = struct { key: []const u8, value: []const u8 };
pub const GetExCommand = struct { key: []const u8 }; // Simplified for now

// --- Key Management Commands ---
pub const DelCommand = struct { keys: []const []const u8 };
pub const ExistsCommand = struct { keys: []const []const u8 };
pub const ExpireCommand = struct { key: []const u8, seconds: i64 };
pub const ExpireAtCommand = struct { key: []const u8, timestamp: i64 };
pub const ExpireTimeCommand = struct { key: []const u8 };
pub const FlushDbCommand = struct {};
pub const KeysCommand = struct { pattern: []const u8 };
pub const TtlCommand = struct { key: []const u8 };
pub const TypeCommand = struct { key: []const u8 };

// --- Hash Commands ---
pub const FieldValuePair = struct { field: []const u8, value: []const u8 };
pub const HSetCommand = struct { key: []const u8, pairs: []const FieldValuePair };
pub const HGetCommand = struct { key: []const u8, field: []const u8 };
pub const HGetAllCommand = struct { key: []const u8 };

// --- Sorted Set Commands ---
pub const ScoreMemberPair = struct { score: f64, member: []const u8 };
pub const ZAddCommand = struct { key: []const u8, members: []const ScoreMemberPair };
pub const ZCardCommand = struct { key: []const u8 };
pub const ZCountCommand = struct { key: []const u8, min: []const u8, max: []const u8 };
pub const ZPopMaxCommand = struct { key: []const u8, count: u64 };
pub const ZPopMinCommand = struct { key: []const u8, count: u64 };
pub const ZRangeCommand = struct { key: []const u8, start: i64, stop: i64, with_scores: bool };
pub const ZRankCommand = struct { key: []const u8, member: []const u8 };
pub const ZRemCommand = struct { key: []const u8, members: []const []const u8 };

// --- Connection/Server Commands ---
pub const PingCommand = struct { message: ?[]const u8 };
pub const EchoCommand = struct { message: []const u8 };
pub const ClientSetInfoCommand = struct { key: []const u8, value: []const u8 };
pub const ClientCommand = union(enum) {
    setinfo: ClientSetInfoCommand,
};

//==============================================================================
//  Error Types
//==============================================================================

pub const ParseError = error{
    UnclosedQuote,
    EmptyCommand,
    UnexpectedEnd,
    InvalidFormat,
    ExpectedCRLF,
    InvalidInteger,
    IncompleteCommand,
    InvalidBulkString,
    OutOfMemory,
};

pub const CommandError = error{
    WrongNumberOfArguments,
    InvalidArgumentType,
    InvalidCommandFormat,
    OutOfMemory,
    WrongType,
};

pub const Command = struct {
    name: []const u8,
    args: []const []const u8,
    allocator: std.mem.Allocator,

    /// Frees the memory allocated for the name and arguments
    pub fn deinit(self: Command) void {
        self.allocator.free(self.name);
        for (self.args) |arg| {
            self.allocator.free(arg);
        }
        self.allocator.free(self.args);
    }

    // --- String Command Parsers ---
    pub fn asGet(s: Command) CommandError!GetCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return GetCommand{ .key = s.args[0] };
    }
    pub fn asSet(s: Command) CommandError!SetCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        return SetCommand{ .key = s.args[0], .value = s.args[1] };
    }
    pub fn asIncr(s: Command) CommandError!IncrCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return IncrCommand{ .key = s.args[0] };
    }
    pub fn asDecr(s: Command) CommandError!DecrCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return DecrCommand{ .key = s.args[0] };
    }
    pub fn asIncrBy(s: Command) CommandError!IncrByCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        const amt = std.fmt.parseInt(i64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        return IncrByCommand{ .key = s.args[0], .amount = amt };
    }
    pub fn asDecrBy(s: Command) CommandError!DecrByCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        const amt = std.fmt.parseInt(i64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        return DecrByCommand{ .key = s.args[0], .amount = amt };
    }
    pub fn asGetDel(s: Command) CommandError!GetDelCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return GetDelCommand{ .key = s.args[0] };
    }
    pub fn asGetSet(s: Command) CommandError!GetSetCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        return GetSetCommand{ .key = s.args[0], .value = s.args[1] };
    }
    pub fn asGetEx(s: Command) CommandError!GetExCommand {
        if (s.args.len < 1) return CommandError.WrongNumberOfArguments;
        return GetExCommand{ .key = s.args[0] };
    }

    // --- Key Management Parsers ---
    pub fn asDel(s: Command) CommandError!DelCommand {
        if (s.args.len < 1) return CommandError.WrongNumberOfArguments;
        return DelCommand{ .keys = s.args };
    }
    pub fn asExists(s: Command) CommandError!ExistsCommand {
        if (s.args.len < 1) return CommandError.WrongNumberOfArguments;
        return ExistsCommand{ .keys = s.args };
    }
    pub fn asExpire(s: Command) CommandError!ExpireCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        const sec = std.fmt.parseInt(i64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        return ExpireCommand{ .key = s.args[0], .seconds = sec };
    }
    pub fn asExpireAt(s: Command) CommandError!ExpireAtCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        const ts = std.fmt.parseInt(i64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        return ExpireAtCommand{ .key = s.args[0], .timestamp = ts };
    }
    pub fn asExpireTime(s: Command) CommandError!ExpireTimeCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return ExpireTimeCommand{ .key = s.args[0] };
    }
    pub fn asFlushDb(s: Command) CommandError!FlushDbCommand {
        if (s.args.len != 0) return CommandError.WrongNumberOfArguments;
        return FlushDbCommand{};
    }
    pub fn asKeys(s: Command) CommandError!KeysCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return KeysCommand{ .pattern = s.args[0] };
    }
    pub fn asTtl(s: Command) CommandError!TtlCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return TtlCommand{ .key = s.args[0] };
    }
    pub fn asType(s: Command) CommandError!TypeCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return TypeCommand{ .key = s.args[0] };
    }

    // --- Hash Parsers ---
    pub fn asHSet(s: Command) CommandError!HSetCommand {
        if (s.args.len < 3 or (s.args.len - 1) % 2 != 0) return CommandError.WrongNumberOfArguments;
        const pairs = try s.allocator.alloc(FieldValuePair, (s.args.len - 1) / 2);
        errdefer s.allocator.free(pairs);
        for (0..pairs.len) |i| {
            pairs[i] = .{ .field = s.args[i * 2 + 1], .value = s.args[i * 2 + 2] };
        }
        return HSetCommand{ .key = s.args[0], .pairs = pairs };
    }
    pub fn asHGet(s: Command) CommandError!HGetCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        return HGetCommand{ .key = s.args[0], .field = s.args[1] };
    }
    pub fn asHGetAll(s: Command) CommandError!HGetAllCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return HGetAllCommand{ .key = s.args[0] };
    }

    // --- Sorted Set Parsers ---
    pub fn asZAdd(s: Command) CommandError!ZAddCommand {
        if (s.args.len < 3 or (s.args.len - 1) % 2 != 0) return CommandError.WrongNumberOfArguments;
        const members = try s.allocator.alloc(ScoreMemberPair, (s.args.len - 1) / 2);
        errdefer s.allocator.free(members);
        for (0..members.len) |i| {
            const score_str = s.args[i * 2 + 1];
            const member_str = s.args[i * 2 + 2];
            const score = std.fmt.parseFloat(f64, score_str) catch return CommandError.InvalidArgumentType;
            members[i] = .{ .score = score, .member = member_str };
        }
        return ZAddCommand{ .key = s.args[0], .members = members };
    }
    pub fn asZCard(s: Command) CommandError!ZCardCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return ZCardCommand{ .key = s.args[0] };
    }
    pub fn asZCount(s: Command) CommandError!ZCountCommand {
        if (s.args.len != 3) return CommandError.WrongNumberOfArguments;
        return ZCountCommand{ .key = s.args[0], .min = s.args[1], .max = s.args[2] };
    }
    pub fn asZPopMax(s: Command) CommandError!ZPopMaxCommand {
        if (s.args.len < 1 or s.args.len > 2) return CommandError.WrongNumberOfArguments;
        var count: u64 = 1;
        if (s.args.len == 2) {
            count = std.fmt.parseInt(u64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        }
        return ZPopMaxCommand{ .key = s.args[0], .count = count };
    }
    pub fn asZPopMin(s: Command) CommandError!ZPopMinCommand {
        if (s.args.len < 1 or s.args.len > 2) return CommandError.WrongNumberOfArguments;
        var count: u64 = 1;
        if (s.args.len == 2) {
            count = std.fmt.parseInt(u64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        }
        return ZPopMinCommand{ .key = s.args[0], .count = count };
    }
    pub fn asZRange(s: Command) CommandError!ZRangeCommand {
        if (s.args.len < 3 or s.args.len > 4) return CommandError.WrongNumberOfArguments;
        const start = std.fmt.parseInt(i64, s.args[1], 10) catch return CommandError.InvalidArgumentType;
        const stop = std.fmt.parseInt(i64, s.args[2], 10) catch return CommandError.InvalidArgumentType;
        var with_scores = false;
        if (s.args.len == 4) {
            const third_arg = try toUpperAlloc(s.allocator, s.args[3]);
            defer s.allocator.free(third_arg);
            if (std.mem.eql(u8, "WITHSCORES", third_arg)) {
                with_scores = true;
            } else {
                return CommandError.InvalidCommandFormat;
            }
        }
        return ZRangeCommand{ .key = s.args[0], .start = start, .stop = stop, .with_scores = with_scores };
    }
    pub fn asZRank(s: Command) CommandError!ZRankCommand {
        if (s.args.len != 2) return CommandError.WrongNumberOfArguments;
        return ZRankCommand{ .key = s.args[0], .member = s.args[1] };
    }
    pub fn asZRem(s: Command) CommandError!ZRemCommand {
        if (s.args.len < 2) return CommandError.WrongNumberOfArguments;
        return ZRemCommand{ .key = s.args[0], .members = s.args[1..] };
    }

    // --- Connection/Server Parsers ---
    pub fn asPing(s: Command) CommandError!PingCommand {
        if (s.args.len > 1) return CommandError.WrongNumberOfArguments;
        var msg: ?[]const u8 = null;
        if (s.args.len == 1) {
            msg = s.args[0];
        }
        return PingCommand{ .message = msg };
    }
    pub fn asEcho(s: Command) CommandError!EchoCommand {
        if (s.args.len != 1) return CommandError.WrongNumberOfArguments;
        return EchoCommand{ .message = s.args[0] };
    }
    pub fn asClient(s: Command) CommandError!ClientCommand {
        if (s.args.len < 1) return CommandError.WrongNumberOfArguments;

        if (std.ascii.eqlIgnoreCase(s.args[0], "SETINFO")) {
            if (s.args.len != 3) return CommandError.WrongNumberOfArguments;
            return ClientCommand{ .setinfo = .{ .key = s.args[1], .value = s.args[2] } };
        }

        return CommandError.InvalidCommandFormat; // Unknown subcommand
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

//==============================================================================
//  Helper Functions
//==============================================================================

/// Takes a generic `Command` and dispatches it to the correct parser, printing
/// the details of the strongly-typed result or any errors that occur.
/// This function encapsulates the command processing and printing logic.
///
/// - `allocator`: An allocator needed for heap allocations within specific command
///   parsers (e.g., for HSET and ZADD).
/// - `command`: The generic `Command` struct to be processed.
fn printCommandDetails(allocator: std.mem.Allocator, command: Command) !void {
    const stdout = std.io.getStdOut().writer();

    // For case-insensitive command matching, convert the command name to uppercase.
    // We use a stack buffer to avoid heap allocation for this common operation.
    const upper_name = try toUpperAlloc(allocator, command.name);
    defer allocator.free(upper_name);

    // Dispatch to the correct command parser based on the command name.
    if (std.mem.eql(u8, upper_name, "GET")) {
        const cmd = command.asGet() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed GET: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "SET")) {
        const cmd = command.asSet() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed SET: key='{s}', value='{s}'\n", .{ cmd.key, cmd.value });
    } else if (std.mem.eql(u8, upper_name, "INCR")) {
        const cmd = command.asIncr() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed INCR: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "DECR")) {
        const cmd = command.asDecr() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed DECR: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "INCRBY")) {
        const cmd = command.asIncrBy() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed INCRBY: key='{s}', amount={d}\n", .{ cmd.key, cmd.amount });
    } else if (std.mem.eql(u8, upper_name, "DECRBY")) {
        const cmd = command.asDecrBy() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed DECRBY: key='{s}', amount={d}\n", .{ cmd.key, cmd.amount });
    } else if (std.mem.eql(u8, upper_name, "GETDEL")) {
        const cmd = command.asGetDel() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed GETDEL: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "GETSET")) {
        const cmd = command.asGetSet() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed GETSET: key='{s}', value='{s}'\n", .{ cmd.key, cmd.value });
    } else if (std.mem.eql(u8, upper_name, "GETEX")) {
        const cmd = command.asGetEx() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed GETEX: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "DEL")) {
        const cmd = command.asDel() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed DEL: keys_count={d}\n", .{cmd.keys.len});
    } else if (std.mem.eql(u8, upper_name, "EXISTS")) {
        const cmd = command.asExists() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed EXISTS: keys_count={d}\n", .{cmd.keys.len});
    } else if (std.mem.eql(u8, upper_name, "EXPIRE")) {
        const cmd = command.asExpire() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed EXPIRE: key='{s}', seconds={d}\n", .{ cmd.key, cmd.seconds });
    } else if (std.mem.eql(u8, upper_name, "EXPIREAT")) {
        const cmd = command.asExpireAt() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed EXPIREAT: key='{s}', timestamp={d}\n", .{ cmd.key, cmd.timestamp });
    } else if (std.mem.eql(u8, upper_name, "EXPIRETIME")) {
        const cmd = command.asExpireTime() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed EXPIRETIME: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "FLUSHDB")) {
        _ = command.asFlushDb() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed FLUSHDB\n", .{});
    } else if (std.mem.eql(u8, upper_name, "KEYS")) {
        const cmd = command.asKeys() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed KEYS: pattern='{s}'\n", .{cmd.pattern});
    } else if (std.mem.eql(u8, upper_name, "TTL")) {
        const cmd = command.asTtl() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed TTL: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "TYPE")) {
        const cmd = command.asType() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed TYPE: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "HSET")) {
        const cmd = command.asHSet() catch |e| {
            return printCmdErr(e);
        };
        defer allocator.free(cmd.pairs);
        try stdout.print("  Parsed HSET: key='{s}', pairs_count={d}\n", .{ cmd.key, cmd.pairs.len });
    } else if (std.mem.eql(u8, upper_name, "HGET")) {
        const cmd = command.asHGet() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed HGET: key='{s}', field='{s}'\n", .{ cmd.key, cmd.field });
    } else if (std.mem.eql(u8, upper_name, "HGETALL")) {
        const cmd = command.asHGetAll() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed HGETALL: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "ZADD")) {
        const cmd = command.asZAdd() catch |e| {
            return printCmdErr(e);
        };
        defer allocator.free(cmd.members);
        try stdout.print("  Parsed ZADD: key='{s}', members_count={d}\n", .{ cmd.key, cmd.members.len });
    } else if (std.mem.eql(u8, upper_name, "ZCARD")) {
        const cmd = command.asZCard() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZCARD: key='{s}'\n", .{cmd.key});
    } else if (std.mem.eql(u8, upper_name, "ZCOUNT")) {
        const cmd = command.asZCount() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZCOUNT: key='{s}', min='{s}', max='{s}'\n", .{ cmd.key, cmd.min, cmd.max });
    } else if (std.mem.eql(u8, upper_name, "ZPOPMAX")) {
        const cmd = command.asZPopMax() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZPOPMAX: key='{s}', count={d}\n", .{ cmd.key, cmd.count });
    } else if (std.mem.eql(u8, upper_name, "ZPOPMIN")) {
        const cmd = command.asZPopMin() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZPOPMIN: key='{s}', count={d}\n", .{ cmd.key, cmd.count });
    } else if (std.mem.eql(u8, upper_name, "ZRANGE")) {
        const cmd = command.asZRange() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZRANGE: key='{s}', start={d}, stop={d}, with_scores={any}\n", .{ cmd.key, cmd.start, cmd.stop, cmd.with_scores });
    } else if (std.mem.eql(u8, upper_name, "ZRANK")) {
        const cmd = command.asZRank() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZRANK: key='{s}', member='{s}'\n", .{ cmd.key, cmd.member });
    } else if (std.mem.eql(u8, upper_name, "ZREM")) {
        const cmd = command.asZRem() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ZREM: key='{s}', members_count={d}\n", .{ cmd.key, cmd.members.len });
    } else if (std.mem.eql(u8, upper_name, "PING")) {
        const cmd = command.asPing() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed PING: message='{?s}'\n", .{cmd.message});
    } else if (std.mem.eql(u8, upper_name, "ECHO")) {
        const cmd = command.asEcho() catch |e| {
            return printCmdErr(e);
        };
        try stdout.print("  Parsed ECHO: message='{s}'\n", .{cmd.message});
    } else {
        try stdout.print("  Command not implemented in main dispatcher: {s}\n", .{command.name});
    }
}

/// Helper function to print command-specific errors to stdout.
fn printCmdErr(err: CommandError) !void {
    try std.io.getStdOut().writer().print("  Command Error: {s}\n", .{@errorName(err)});
}

/// Helper function to convert string to upper case
pub fn toUpperAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Allocate memory for the uppercase string.
    const len = input.len;
    var result = try allocator.alloc(u8, len);

    // Convert each byte to uppercase and copy.
    for (input, 0..) |byte, i| {
        result[i] = std.ascii.toUpper(byte);
    }

    return result;
}

/// A generic wrapper struct to customize printing.
/// Takes the type 'T' of the value it wraps.
fn PrinterWrapper(comptime T: type) type {
    return struct {
        value: T, // The actual value being wrapped

        // This function is automatically called by std.debug.print, std.fmt.format, etc.
        pub fn format(
            self: PrinterWrapper(T), // The instance of the wrapper struct
            comptime fmt_str: []const u8, // The format specifier string (e.g., "s", "d", "any") - mostly ignored here
            options: fmt.FormatOptions, // Formatting options (alignment, etc.) - ignored here
            writer: anytype, // The output stream (e.g., stdout writer)
        ) !void {
            // Add a prefix and use the original value's default formatting
            try writer.print("[Wrapped: ", .{});
            // Use std.fmt.formatType to format the inner value using its own format rules
            try fmt.formatType(
                self.value,
                fmt_str,
                options,
                writer,
                std.options.fmt_max_depth,
            );
            try writer.print("]", .{});
        }
    };
}

// 2. Create a helper function to easily create the wrapper (optional but convenient)
fn wrapIt(value: anytype) PrinterWrapper(@TypeOf(value)) {
    // The @TypeOf builtin gets the type of the value at compile time
    return PrinterWrapper(@TypeOf(value)){ .value = value };
}

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

        const result = parseCommand(allocator, data);
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

fn handleCommand(allocator: std.mem.Allocator, cmd: Command, state: *SharedState, client_info: *ClientInfo) ![]const u8 {
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

    const cmd_upper_name = try toUpperAlloc(allocator, cmd.name);
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

pub fn parseCommand(allocator: Allocator, input: []const u8) ParseError!Command {
    if (input.len == 0) return ParseError.EmptyCommand;

    // Check for RESP protocol (starts with '*')
    if (input[0] == '*') {
        return parseRespCommand(allocator, input);
    }
    // Handle inline command (netcat style)
    else {
        return parseSimpleCommand(allocator, input);
    }
}

fn parseSimpleCommand(allocator: Allocator, input: []const u8) ParseError!Command {
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer tokens.deinit();

    var i: usize = 0;
    while (i < input.len) {
        // Skip whitespace
        while (i < input.len and std.ascii.isWhitespace(input[i])) i += 1;
        if (i >= input.len) break;

        const start = i;

        // Handle quoted strings
        if (input[i] == '"') {
            i += 1; // Skip opening quote
            const token_start = i;
            while (i < input.len and input[i] != '"') i += 1;
            if (i >= input.len) return ParseError.UnclosedQuote;

            try tokens.append(input[token_start..i]);
            i += 1; // Skip closing quote
        }
        // Handle regular tokens
        else {
            while (i < input.len and !std.ascii.isWhitespace(input[i])) i += 1;
            try tokens.append(input[start..i]);
        }
    }

    if (tokens.items.len == 0) return ParseError.EmptyCommand;

    // Duplicate and own all tokens
    const name = try allocator.dupe(u8, tokens.items[0]);
    errdefer allocator.free(name);

    const args = try allocator.alloc([]const u8, tokens.items.len - 1);
    for (tokens.items[1..], 0..) |token, idx| {
        args[idx] = try allocator.dupe(u8, token);
    }

    return Command{
        .name = name,
        .args = args,
        .allocator = allocator,
    };
}

fn parseRespCommand(allocator: Allocator, input: []const u8) ParseError!Command {
    var index: usize = 1; // Skip initial '*'
    const element_count = try parseIntegerUntilCRLF(input, &index);
    if (element_count < 1) return ParseError.InvalidFormat;

    var tokens = std.ArrayList([]const u8).init(allocator);
    defer {
        if (tokens.items.len > 0) {
            for (tokens.items) |token| allocator.free(token);
        }
        tokens.deinit();
    }

    // Parse each element
    for (0..element_count) |_| {
        if (index >= input.len) return ParseError.UnexpectedEnd;
        if (input[index] != '$') return ParseError.InvalidFormat;
        index += 1;

        const str_len = try parseIntegerUntilCRLF(input, &index);
        if (index + str_len + 2 > input.len) return ParseError.UnexpectedEnd;

        const token = input[index .. index + str_len];
        index += str_len + 2; // Skip token + CRLF

        // Duplicate and own the token
        const token_dup = try allocator.dupe(u8, token);
        try tokens.append(token_dup);
    }

    if (tokens.items.len == 0) return ParseError.EmptyCommand;

    // Extract command name and arguments
    const name = tokens.orderedRemove(0);
    const args = try tokens.toOwnedSlice();

    return Command{
        .name = name,
        .args = args,
        .allocator = allocator,
    };
}

fn parseIntegerUntilCRLF(input: []const u8, index: *usize) ParseError!u32 {
    const start = index.*;
    var end = start;

    // Find CRLF position
    while (end < input.len - 1) : (end += 1) {
        if (input[end] == '\r' and input[end + 1] == '\n') break;
    }
    if (end >= input.len - 1) return ParseError.ExpectedCRLF;

    // Parse integer value
    const num_str = input[start..end];
    const num = std.fmt.parseUnsigned(u32, num_str, 10) catch {
        return ParseError.InvalidInteger;
    };

    index.* = end + 2; // Skip CRLF
    return num;
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
    var cmd = try parseCommand(test_allocator, input);
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
    try testing.expectError(ParseError.EmptyCommand, parseCommand(test_allocator, ""));

    // Incomplete RESP
    try testing.expectError(ParseError.UnexpectedEnd, parseCommand(test_allocator, "*2\r\n$3\r\nGET"));

    // Invalid FORMAT
    try testing.expectError(ParseError.InvalidInteger, parseCommand(test_allocator, "*abc\r\n"));

    // Missing CRLF
    try testing.expectError(ParseError.ExpectedCRLF, parseCommand(test_allocator, "*1"));

    // Unclosed quote
    try testing.expectError(ParseError.UnclosedQuote, parseCommand(test_allocator, "SET name \"value"));

    // Invalid bulk string header
    try testing.expectError(ParseError.InvalidFormat, parseCommand(test_allocator, "*1\r\nabc\r\n"));

    // Negative element count
    try testing.expectError(ParseError.InvalidInteger, parseCommand(test_allocator, "*-1\r\n"));
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
