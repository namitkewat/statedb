const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

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
