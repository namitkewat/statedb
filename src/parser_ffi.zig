const std = @import("std");
// Assuming db_parser.zig contains the `parse` function that returns a Command struct.
const db_parser = @import("lib.zig");
const json = std.json;

/// This is the C-compatible struct that will be passed to Node.js.
/// The pointers are null-terminated C strings, which are easy to read
/// from JavaScript.
pub const ParseResult = extern struct {
    success: bool,
    /// On error, this contains the error message. Otherwise, it's null.
    err: ?[*:0]const u8,
    /// On success, this contains the JSON result. Otherwise, it's null.
    json_result: ?[*:0]const u8,
};

/// This is the primary function that will be called from Node.js.
/// It takes a null-terminated RESP command string as input.
/// It returns a pointer to a ParseResult struct. The caller in Node.js
/// is responsible for calling `free_parse_result` on this pointer later.
export fn parse_command(input: [*:0]const u8) *ParseResult {
    // Use the C allocator because this memory will be managed across the FFI boundary.
    const allocator = std.heap.c_allocator;

    // Use a temporary Arena for parsing, which simplifies cleanup within this function.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const input_slice = std.mem.span(input);

    // Parse the command using the arena allocator for temporary allocations.
    const command = db_parser.parseCommand(arena_alloc, input_slice) catch |err| {
        // If parsing fails, create and return an error result.
        return createErrorResult(allocator, @errorName(err));
    };
    // The command struct itself and its contents will be freed when the arena is deinitialized.

    const SerializableCommand = struct {
        name: []const u8,
        args: []const []const u8,
    };

    const serializable_cmd = SerializableCommand{
        .name = command.name,
        .args = command.args,
    };

    // Serialize the parsed command to a JSON string.
    // This allocation also happens on the temporary arena.
    const json_str_slice = json.stringifyAlloc(arena_alloc, serializable_cmd, .{}) catch |err| {
        return createErrorResult(allocator, @errorName(err));
    };

    // --- Prepare the final result for the C caller ---

    // 1. Allocate the ParseResult struct itself on the C heap.
    const result = allocator.create(ParseResult) catch |err| {
        return createErrorResult(allocator, @errorName(err));
    };

    // 2. Create a null-terminated duplicate of the JSON string on the C heap.
    // This is the CRITICAL FIX for the type error.
    const final_json_str = allocator.dupeZ(u8, json_str_slice) catch |err| {
        allocator.destroy(result); // Clean up the result struct if this fails
        return createErrorResult(allocator, @errorName(err));
    };

    // Populate the struct with the pointers to the C-heap-allocated strings.
    result.* = .{
        .success = true,
        .err = null, // No error
        .json_result = final_json_str.ptr,
    };

    return result;
}

/// This function MUST be called from Node.js to free the memory that was
/// allocated by `parse_command`. Failure to do so will result in a memory leak.
export fn free_parse_result(result: *ParseResult) void {
    const allocator = std.heap.c_allocator;

    // This checks if the pointer is not null before trying to free it.
    if (result.json_result) |json_ptr| {
        allocator.free(std.mem.span(json_ptr));
    }
    if (result.err) |err_ptr| {
        allocator.free(std.mem.span(err_ptr));
    }

    // Finally, free the ParseResult struct itself.
    allocator.destroy(result);
}

/// Helper function to create an error result struct.
/// It allocates memory using the provided allocator.
fn createErrorResult(allocator: std.mem.Allocator, msg: []const u8) *ParseResult {
    // This function must not fail, so we use `unreachable` on allocation failure.
    // In a real production library, you might want a more graceful OOM handling.
    const result = allocator.create(ParseResult) catch unreachable;
    const err_str = allocator.dupeZ(u8, msg) catch unreachable;

    result.* = .{
        .success = false,
        .err = err_str.ptr,
        .json_result = null, // No JSON result on error
    };
    return result;
}
