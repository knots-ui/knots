const std = @import("std");

pub const Kind = enum { module, helper };

pub fn kind(bytes: []const u8) !Kind {
    std.debug.assert(@sizeOf(u32) == 4);
    std.debug.assert(bytes.len <= 32 * 1024 * 1024);

    if (bytes.len < 8)
        return error.InvalidWasm;

    if (!std.mem.eql(u8, bytes[0..8], "\x00asm\x01\x00\x00\x00"))
        return error.InvalidWasm;

    var offset: usize = 8;
    var result: ?Kind = null;
    while (offset < bytes.len) {
        const section = bytes[offset];
        offset += 1;
        const length = try unsigned(bytes, &offset);
        if (length > bytes.len - offset)
            return error.InvalidWasm;

        const end = offset + length;
        if (section == 7) {
            const exports = try unsigned(bytes[0..end], &offset);
            if (exports > length)
                return error.InvalidWasm;

            for (0..exports) |_| {
                const name_length = try unsigned(bytes[0..end], &offset);
                if (name_length > end - offset)
                    return error.InvalidWasm;

                const name = bytes[offset..][0..name_length];
                offset += name_length;
                if (offset == end)
                    return error.InvalidWasm;

                const export_kind = bytes[offset];
                offset += 1;
                _ = try unsigned(bytes[0..end], &offset);

                const classification: ?Kind = if (std.mem.eql(u8, name, "knots_hmr_module"))
                    .module
                else if (std.mem.eql(u8, name, "knots_hmr_helper"))
                    .helper
                else
                    null;

                if (classification) |value| {
                    if (export_kind != 0)
                        return error.InvalidClassification;
                    if (result != null)
                        return error.DuplicateClassification;
                    result = value;
                }
            }

            if (offset != end)
                return error.InvalidWasm;
        }
        offset = end;
    }

    return result orelse error.MissingClassification;
}

fn unsigned(bytes: []const u8, offset: *usize) !u32 {
    std.debug.assert(offset.* <= bytes.len);
    std.debug.assert(@bitSizeOf(u32) == 32);

    var value: u32 = 0;
    for (0..5) |index| {
        if (offset.* == bytes.len)
            return error.InvalidWasm;

        const byte = bytes[offset.*];
        offset.* += 1;
        if (index == 4) {
            if (byte > 15)
                return error.InvalidWasm;
        }

        value |= @as(u32, byte & 127) << @as(u5, @intCast(index * 7));
        if (byte < 128)
            return value;
    }

    return error.InvalidWasm;
}
