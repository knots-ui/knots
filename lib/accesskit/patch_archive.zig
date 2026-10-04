//! Makes the AccessKit static archive linkable next to Zig's compiler_rt and other Rust static
//! libraries (e.g. wgpu-native), which all bundle the same runtime pieces:
//!
//! - Drops Rust's `compiler_builtins` members. Zig's compiler_rt provides the same functions and
//!   collides with them on Windows MSVC.
//! - Renames `rust_eh_personality`, the one Rust std symbol other Rust static libraries also define.
//!   The replacement has the same length, so the archive and object layouts are untouched; AccessKit
//!   keeps using its own copy under the new name.
//!
//! Usage: patch_archive <zig exe> <archive> <member list> <output archive> <output response file>

const std = @import("std");

const symbol = "rust_eh_personality";
const replacement = "accesskit_eh_person";

comptime {
    std.debug.assert(symbol.len == replacement.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 6) return error.InvalidArguments;
    const zig_exe, const input, const member_list, const output, const response_file = args[1..6].*;
    const cwd = std.Io.Dir.cwd();

    const archive = try cwd.readFileAlloc(init.io, input, allocator, .unlimited);
    if (std.mem.count(u8, archive, symbol) == 0) return error.SymbolNotFound;
    try cwd.writeFile(init.io, .{ .sub_path = output, .data = try std.mem.replaceOwned(u8, allocator, archive, symbol, replacement) });

    var builtins: std.Io.Writer.Allocating = .init(allocator);
    var members = std.mem.tokenizeAny(u8, try cwd.readFileAlloc(init.io, member_list, allocator, .unlimited), "\r\n");
    while (members.next()) |member| {
        if (std.mem.indexOf(u8, member, "compiler_builtins") != null) try builtins.writer.print("{s}\n", .{member});
    }
    if (builtins.written().len == 0) return error.CompilerBuiltinsNotFound;
    try cwd.writeFile(init.io, .{ .sub_path = response_file, .data = builtins.written() });

    // Windows quoting keeps the backslashes in MSVC member names literal on every host.
    const delete = &.{ zig_exe, "ar", "d", "--rsp-quoting=windows", output, try std.fmt.allocPrint(allocator, "@{s}", .{response_file}) };
    var child = try std.process.spawn(init.io, .{ .argv = delete });
    if (!(try child.wait(init.io)).success()) return error.ZigArFailed;
}
