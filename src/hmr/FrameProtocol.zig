const std = @import("std");
const input = @import("input");
const ui = @import("ui");
const render = @import("render");
const math = @import("math");
const Wire = @import("Wire.zig");

const Writer = Wire.Writer;
const Reader = Wire.Reader;
const Error = Wire.Error;

pub const Request = struct {
    frame: input.FrameInput,
    state_scope: u64,
    state: []const ui.StateBridge.Value = &.{},
};

pub const Effects = struct {
    cursor_shape: input.CursorShape = .default,
    capture_pointer: bool = false,
    capture_keyboard: bool = false,
    text_input: bool = false,
    redraw: bool = false,
    close: bool = false,
    clipboard_write: ?[]const u8 = null,
};

pub const Contribution = struct {
    packet: render.Packet,
};

pub const Response = struct {
    contribution: Contribution,
    state: []const ui.StateBridge.Value = &.{},
    dependencies: []const ui.StateBridge.Dependency = &.{},
    effects: Effects = .{},
};

pub fn encodeRequest(writer: *Writer, request: *const Request) Error!void {
    try writer.int(u32, Wire.version);
    const frame = &request.frame;
    if (request.state_scope == 0) return error.InvalidWire;
    try writer.int(u64, request.state_scope);
    try writer.int(i64, frame.now_ms);
    try writer.int(u64, frame.delta_ns);
    try writer.record(frame.logical_extent);
    try writer.record(frame.physical_extent);
    try writer.float(f32, frame.content_scale);
    const event = &frame.input;
    try writer.boolean(event.focused);
    for (event.pos) |value| try writer.float(f64, value);
    for (event.mouse) |button| {
        try writer.boolean(button.down);
        try writer.boolean(button.pressed);
        try writer.boolean(button.released);
        inline for (.{ button.pressed_pos, button.released_pos }) |position| {
            try writer.boolean(position != null);
            if (position) |point| for (point) |value| {
                try writer.float(f64, value);
            };
        }
    }
    try writer.record(event.scroll);
    try writeCount(writer, event.chars.len);
    for (event.chars) |value| try writer.int(u32, value);
    try writeCount(writer, event.key_events.len);
    for (event.key_events) |key| {
        try writer.int(i32, @backingInt(key.key));
        try writer.int(u32, @backingInt(key.action));
        try writer.int(u8, @bitCast(key.mods));
    }
    for (event.key_down) |down| try writer.boolean(down);
    inline for (.{ event.shift_held, event.ctrl_held, event.alt_held, event.super_held }) |held| try writer.boolean(held);
    try writer.boolean(frame.paste_text != null);
    if (frame.paste_text) |value| try writer.bytes(value);
    try writeCount(writer, frame.dropped_paths.len);
    for (frame.dropped_paths) |path| try writer.bytes(path);
    try writeState(writer, request.state);
}

/// Allocations and borrowed wire bytes must live through the module frame.
pub fn decodeRequest(allocator: std.mem.Allocator, bytes: []const u8) Error!Request {
    var reader: Reader = .{ .data = bytes };
    if (try reader.int(u32) != Wire.version) return error.UnsupportedVersion;
    const state_scope = try reader.int(u64);
    if (state_scope == 0) return error.InvalidWire;
    var frame: input.FrameInput = undefined;
    frame.now_ms = try reader.int(i64);
    frame.delta_ns = try reader.int(u64);
    frame.logical_extent = try reader.record(input.Size);
    frame.physical_extent = try reader.record(input.Size);
    frame.content_scale = try reader.float(f32);
    if (frame.logical_extent.width == 0) return error.InvalidWire;
    if (frame.logical_extent.height == 0) return error.InvalidWire;
    if (frame.physical_extent.width == 0) return error.InvalidWire;
    if (frame.physical_extent.height == 0) return error.InvalidWire;
    if (frame.content_scale <= 0) return error.InvalidWire;
    frame.input = .{ .focused = try reader.boolean(), .pos = .{ try reader.float(f64), try reader.float(f64) } };
    for (&frame.input.mouse) |*button| {
        button.down = try reader.boolean();
        button.pressed = try reader.boolean();
        button.released = try reader.boolean();
        button.pressed_pos = if (try reader.boolean()) .{ try reader.float(f64), try reader.float(f64) } else null;
        button.released_pos = if (try reader.boolean()) .{ try reader.float(f64), try reader.float(f64) } else null;
    }
    frame.input.scroll = try reader.record(input.ScrollInput);
    inline for (@typeInfo(input.ScrollInput).@"struct".field_names) |name| {
        for (@field(frame.input.scroll, name)) |value| {
            if (!std.math.isFinite(value)) return error.InvalidWire;
        }
    }
    const chars = try allocator.alloc(u21, try readCount(&reader, 4));
    for (chars) |*value| {
        const scalar = try reader.int(u32);
        if (scalar > 0x10ffff) return error.InvalidWire;
        if (scalar >= 0xd800) {
            if (scalar <= 0xdfff) return error.InvalidWire;
        }
        value.* = @intCast(scalar);
    }
    frame.input.chars = chars;
    const keys = try allocator.alloc(input.KeyEvent, try readCount(&reader, 9));
    for (keys) |*key| {
        const code = try reader.int(i32);
        if (code < 0) return error.InvalidWire;
        if (code >= input.key_count) return error.InvalidWire;
        key.key = @fromBackingInt(@intCast(code));
        key.action = try reader.enumeration(input.KeyAction);
        const mods = try reader.int(u8);
        if (mods > 15) return error.InvalidWire;
        key.mods = @bitCast(mods);
    }
    frame.input.key_events = keys;
    const down = try allocator.create([input.key_count]bool);
    for (down) |*value| value.* = try reader.boolean();
    frame.input.key_down = down;
    frame.input.shift_held = try reader.boolean();
    frame.input.ctrl_held = try reader.boolean();
    frame.input.alt_held = try reader.boolean();
    frame.input.super_held = try reader.boolean();
    frame.paste_text = if (try reader.boolean()) try reader.bytes() else null;
    const paths = try allocator.alloc([]const u8, try readCount(&reader, 4));
    for (paths) |*path| path.* = try reader.bytes();
    frame.dropped_paths = paths;
    const state = try readState(&reader, allocator);
    try reader.end();
    return .{ .frame = frame, .state_scope = state_scope, .state = state };
}

pub fn encodeResponse(writer: *Writer, response: *const Response) Error!void {
    try writer.int(u32, Wire.version);
    const effects = &response.effects;
    try writer.int(u32, @backingInt(effects.cursor_shape));
    inline for (.{ effects.capture_pointer, effects.capture_keyboard, effects.text_input, effects.redraw, effects.close }) |value| try writer.boolean(value);
    try writer.boolean(effects.clipboard_write != null);
    if (effects.clipboard_write) |value| try writer.bytes(value);
    try writeState(writer, response.state);
    try writeDependencies(writer, response.dependencies);
    const packet = &response.contribution.packet;
    try writeRecords(writer, packet.primitiveVertices());
    try writeCount(writer, packet.primitiveIndices().len);
    for (packet.primitiveIndices()) |index| try writer.int(u32, index);
    try writeRecords(writer, packet.instances());
    try writeRecords(writer, packet.textInstances());
    try writeRecords(writer, packet.clipNodes());
    try writer.boolean(packet.glyphAtlas() != null);
    if (packet.glyphAtlas()) |atlas| {
        try writer.int(u32, atlas.id);
        try writer.int(u64, atlas.revision);
        try writer.int(u64, atlas.base_revision);
        try writer.int(u32, atlas.curve_row_start);
        try writer.int(u32, atlas.band_row_start);
        try writer.bytes(atlas.curve);
        try writer.bytes(atlas.band);
    }
    try writeCount(writer, packet.commands().len);
    for (packet.commands()) |command| {
        try writer.int(u32, command.clip.node);
        try writer.boolean(command.clip.scissor != null);
        if (command.clip.scissor) |rect| for (0..4) |index| {
            try writer.float(f32, @as([4]f32, rect.v)[index]);
        };
        switch (command.payload) {
            .vertex => |draw| {
                try writer.int(u32, 0);
                try writer.int(u32, draw.offset);
                try writer.int(u32, draw.count);
                try writeTexture(writer, draw.texture);
            },
            .instance => |draw| {
                try writer.int(u32, 1);
                try writer.int(u32, draw.offset);
                try writer.int(u32, draw.count);
                try writeTexture(writer, draw.texture);
            },
            .text => |draw| {
                try writer.int(u32, 2);
                try writer.int(u32, draw.offset);
                try writer.int(u32, draw.count);
            },
            .custom_draw => return error.InvalidWire,
        }
    }
}

/// Decode into a caller-owned frame arena. All byte payloads are copied.
pub fn decodeResponse(allocator: std.mem.Allocator, bytes: []const u8) Error!Response {
    var reader: Reader = .{ .data = bytes };
    if (try reader.int(u32) != Wire.version) return error.UnsupportedVersion;
    var result: Response = undefined;
    result.effects.cursor_shape = try reader.enumeration(input.CursorShape);
    result.effects.capture_pointer = try reader.boolean();
    result.effects.capture_keyboard = try reader.boolean();
    result.effects.text_input = try reader.boolean();
    result.effects.redraw = try reader.boolean();
    result.effects.close = try reader.boolean();
    result.effects.clipboard_write = if (try reader.boolean()) try allocator.dupe(u8, try reader.bytes()) else null;
    result.state = try readState(&reader, allocator);
    result.dependencies = try readDependencies(&reader, allocator);
    const vertices = try readRecords(&reader, allocator, render.types.Vertex);
    const indices = try allocator.alloc(u32, try readCount(&reader, 4));
    for (indices) |*index| {
        index.* = try reader.int(u32);
        if (index.* >= vertices.len) return error.InvalidWire;
    }
    const instances = try readRecords(&reader, allocator, render.types.Instance);
    const texts = try readRecords(&reader, allocator, render.types.SlugInstance);
    const clips = try readRecords(&reader, allocator, render.Clip.Node);
    for (clips, 0..) |clip, index| {
        if (index == 0) {
            if (clip.parent != 0) return error.InvalidWire;
        } else {
            if (clip.parent >= index) return error.InvalidWire;
        }
        if (render.Clip.depth(clips, @intCast(index)) >= render.Clip.MAX_DEPTH) return error.InvalidWire;
        for (clip._pad) |padding| {
            if (padding != 0) return error.InvalidWire;
        }
    }
    for (vertices) |vertex| try validateClip(vertex.clip_node, clips.len);
    for (instances) |instance| try validateClip(instance.clip_node, clips.len);
    for (texts) |text| try validateClip(text.clip_node, clips.len);
    const atlas: ?render.GlyphAtlas = if (try reader.boolean()) blk: {
        const id = try reader.int(u32);
        const revision = try reader.int(u64);
        const base_revision = try reader.int(u64);
        const curve_row_start = try reader.int(u32);
        const band_row_start = try reader.int(u32);
        const curve = try reader.bytes();
        const band = try reader.bytes();
        if (id == 0) return error.InvalidWire;
        if (base_revision > revision) return error.InvalidWire;
        inline for (.{ curve, band }) |plane| {
            if (plane.len > render.GlyphAtlas.plane_bytes_max) return error.LimitExceeded;
            if (plane.len % render.GlyphAtlas.texel_bytes != 0) return error.InvalidWire;
        }
        if (curve_row_start > std.math.divCeil(usize, curve.len, render.GlyphAtlas.row_bytes) catch unreachable) return error.InvalidWire;
        if (band_row_start > std.math.divCeil(usize, band.len, render.GlyphAtlas.row_bytes) catch unreachable) return error.InvalidWire;
        break :blk .{ .id = id, .revision = revision, .base_revision = base_revision, .curve_row_start = curve_row_start, .band_row_start = band_row_start, .curve = try allocator.dupe(u8, curve), .band = try allocator.dupe(u8, band) };
    } else null;
    if (atlas) |*value| try validateGlyphs(allocator, value, texts);
    const commands = try allocator.alloc(render.Command, try readCount(&reader, 17));
    for (commands) |*command| {
        command.clip.node = try reader.int(u32);
        try validateClip(@floatFromInt(command.clip.node), clips.len);
        command.clip.scissor = if (try reader.boolean()) math.Rect.init(try reader.float(f32), try reader.float(f32), try reader.float(f32), try reader.float(f32)) else null;
        const kind = try reader.int(u32);
        const offset = try reader.int(u32);
        const count = try reader.int(u32);
        switch (kind) {
            0 => {
                try validateRange(offset, count, indices.len);
                if (count % 3 != 0) return error.InvalidWire;
                command.payload = .{ .vertex = .{ .offset = offset, .count = count, .texture = try readTexture(&reader, allocator) } };
            },
            1 => {
                try validateRange(offset, count, instances.len);
                command.payload = .{ .instance = .{ .offset = offset, .count = count, .texture = try readTexture(&reader, allocator) } };
            },
            2 => {
                try validateRange(offset, count, texts.len);
                if (atlas == null) return error.InvalidWire;
                command.payload = .{ .text = .{ .offset = offset, .count = count } };
            },
            else => return error.InvalidWire,
        }
    }
    try reader.end();
    result.contribution.packet = .init(commands, vertices, indices, instances, texts, clips, atlas);
    return result;
}

fn writeState(writer: *Writer, values: []const ui.StateBridge.Value) Error!void {
    if (values.len > ui.StateBridge.entries_max) return error.LimitExceeded;
    try writeCount(writer, values.len);
    for (values, 0..) |value, index| {
        if (value.key == 0) return error.InvalidWire;
        if (value.schema == 0) return error.InvalidWire;
        if (value.bytes.len == 0) return error.InvalidWire;
        if (value.bytes.len > ui.StateBridge.value_bytes_max) return error.LimitExceeded;
        for (values[0..index]) |previous| {
            if (previous.domain == value.domain) {
                if (previous.key == value.key) return error.InvalidWire;
            }
        }
        try writer.int(u64, value.domain);
        try writer.int(u64, value.key);
        try writer.int(u64, value.schema);
        try writer.bytes(value.bytes);
    }
}

fn readState(reader: *Reader, allocator: std.mem.Allocator) Error![]ui.StateBridge.Value {
    const count = try readCount(reader, 28);
    if (count > ui.StateBridge.entries_max) return error.LimitExceeded;
    const values = try allocator.alloc(ui.StateBridge.Value, count);
    for (values, 0..) |*value, index| {
        value.* = .{
            .domain = try reader.int(u64),
            .key = try reader.int(u64),
            .schema = try reader.int(u64),
            .bytes = try reader.bytes(),
        };
        if (value.key == 0) return error.InvalidWire;
        if (value.schema == 0) return error.InvalidWire;
        if (value.bytes.len == 0) return error.InvalidWire;
        if (value.bytes.len > ui.StateBridge.value_bytes_max) return error.LimitExceeded;
        for (values[0..index]) |previous| {
            if (previous.domain == value.domain) {
                if (previous.key == value.key) return error.InvalidWire;
            }
        }
    }
    return values;
}

fn writeDependencies(writer: *Writer, dependencies: []const ui.StateBridge.Dependency) Error!void {
    if (dependencies.len > ui.StateBridge.dependencies_max) return error.LimitExceeded;
    try writeCount(writer, dependencies.len);
    for (dependencies, 0..) |dependency, index| {
        if (dependency.key == 0) return error.InvalidWire;
        for (dependencies[0..index]) |previous| {
            if (previous.domain == dependency.domain) {
                if (previous.key == dependency.key) return error.InvalidWire;
            }
        }
        try writer.int(u64, dependency.domain);
        try writer.int(u64, dependency.key);
    }
}

fn readDependencies(reader: *Reader, allocator: std.mem.Allocator) Error![]ui.StateBridge.Dependency {
    const count = try readCount(reader, 16);
    if (count > ui.StateBridge.dependencies_max) return error.LimitExceeded;
    const dependencies = try allocator.alloc(ui.StateBridge.Dependency, count);
    for (dependencies, 0..) |*dependency, index| {
        dependency.* = .{ .domain = try reader.int(u64), .key = try reader.int(u64) };
        if (dependency.key == 0) return error.InvalidWire;
        for (dependencies[0..index]) |previous| {
            if (previous.domain == dependency.domain) {
                if (previous.key == dependency.key) return error.InvalidWire;
            }
        }
    }
    return dependencies;
}

// Atlas planes are GPU texels, not pack records. Validate every shader lookup
// and loop count before allowing guest-controlled bytes onto the GPU.
fn validateGlyphs(allocator: std.mem.Allocator, atlas: *const render.GlyphAtlas, texts: []const render.types.SlugInstance) Error!void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);
    var references: usize = 0;
    var headers: usize = 0;
    var curve_offset: usize = 0;
    while (curve_offset < atlas.curve.len) : (curve_offset += 4) {
        const bits = std.mem.readInt(u32, atlas.curve[curve_offset..][0..4], .little);
        if (!std.math.isFinite(@as(f32, @bitCast(bits)))) return error.InvalidWire;
    }
    for (texts) |text| {
        const location: u32 = @bitCast(text.glyph[0]);
        const bands: u32 = @bitCast(text.glyph[1]);
        const key = (@as(u64, location) << 32) | bands;
        const entry = try seen.getOrPut(allocator, key);
        if (entry.found_existing) continue;
        const x = location & 0xffff;
        const y = location >> 16;
        if (x >= render.GlyphAtlas.width) return error.InvalidWire;
        if (y >= render.GlyphAtlas.width) return error.InvalidWire;
        const vertical_max = bands & 0xffff;
        const horizontal_max = (bands >> 16) & 0xff;
        if (vertical_max > 255) return error.InvalidWire;
        const base = @as(usize, y) * render.GlyphAtlas.width + x;
        const count = vertical_max + horizontal_max + 2;
        if (count > (1 << 20) - headers) return error.LimitExceeded;
        headers += count;
        if (base > atlas.band.len / 16) return error.InvalidWire;
        if (count > atlas.band.len / 16 - base) return error.InvalidWire;
        for (0..count) |index| {
            const header = atlas.band[(base + index) * 16 ..][0..16];
            const curve_count = std.mem.readInt(u32, header[0..4], .little);
            const relative = std.mem.readInt(u32, header[4..8], .little);
            if (curve_count > 4096) return error.LimitExceeded;
            if (curve_count > (1 << 20) - references) return error.LimitExceeded;
            references += curve_count;
            if (relative > atlas.band.len / 16 - base) return error.InvalidWire;
            const start = base + relative;
            if (curve_count > atlas.band.len / 16 - start) return error.InvalidWire;
            for (0..curve_count) |curve_index| {
                const texel = atlas.band[(start + curve_index) * 16 ..][0..16];
                const curve_x = std.mem.readInt(u32, texel[0..4], .little);
                const curve_y = std.mem.readInt(u32, texel[4..8], .little);
                if (curve_x >= render.GlyphAtlas.width) return error.InvalidWire;
                if (curve_y >= render.GlyphAtlas.width) return error.InvalidWire;
                const curve = @as(usize, curve_y) * render.GlyphAtlas.width + curve_x;
                if (curve >= atlas.curve.len / 16) return error.InvalidWire;
                if (atlas.curve.len / 16 - curve < 2) return error.InvalidWire;
            }
        }
    }
}

fn writeCount(writer: *Writer, count: usize) Error!void {
    if (count > Wire.items_max) return error.LimitExceeded;
    try writer.int(u32, @intCast(count));
}

fn readCount(reader: *Reader, minimum_size: usize) Error!u32 {
    std.debug.assert(minimum_size > 0);
    std.debug.assert(reader.offset <= reader.data.len);
    const count = try reader.int(u32);
    if (count > Wire.items_max) return error.LimitExceeded;
    if (count > (reader.data.len - reader.offset) / minimum_size) return error.InvalidWire;
    return count;
}

fn recordSize(comptime T: type) usize {
    var size: usize = 0;
    inline for (@typeInfo(T).@"struct".field_names) |field| size += @sizeOf(@FieldType(T, field));
    return size;
}

fn writeRecords(writer: *Writer, records: anytype) Error!void {
    try writeCount(writer, records.len);
    for (records) |record| try writer.record(record);
}

fn readRecords(reader: *Reader, allocator: std.mem.Allocator, comptime T: type) Error![]T {
    const records = try allocator.alloc(T, try readCount(reader, recordSize(T)));
    for (records) |*record| {
        record.* = try reader.record(T);
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, Field| {
            switch (@typeInfo(Field)) {
                .float => if (!std.math.isFinite(@field(record.*, name))) {
                    return error.InvalidWire;
                },
                .array => |array| if (@typeInfo(array.child) == .float) {
                    for (@field(record.*, name)) |value| if (!std.math.isFinite(value)) return error.InvalidWire;
                },
                else => {},
            }
        }
    }
    return records;
}

fn validateClip(value: f32, count: usize) Error!void {
    if (value < 0) return error.InvalidWire;
    if (value > Wire.items_max) return error.InvalidWire;
    if (@floor(value) != value) return error.InvalidWire;
    if (value == 0) return;
    if (@as(usize, @intFromFloat(value)) >= count) return error.InvalidWire;
}

fn validateRange(offset: u32, count: u32, length: usize) Error!void {
    if (offset > length) return error.InvalidWire;
    if (count > length - offset) return error.InvalidWire;
}

fn writeTexture(writer: *Writer, texture: render.TextureSource) Error!void {
    switch (texture) {
        .atlas => try writer.int(u32, 0),
        .texture => return error.InvalidWire,
        .pixels => |pixels| {
            try writer.int(u32, 1);
            try writer.int(u64, pixels.key);
            try writer.int(u32, pixels.width);
            try writer.int(u32, pixels.height);
            try writer.int(u32, @backingInt(pixels.format));
            try writer.int(u32, pixels.bytes_per_row orelse 0);
            try writer.int(u64, pixels.version);
            try writer.boolean(pixels.force_upload);
            try writer.bytes(pixels.data);
        },
    }
}

fn readTexture(reader: *Reader, allocator: std.mem.Allocator) Error!render.TextureSource {
    switch (try reader.int(u32)) {
        0 => return .atlas,
        1 => {
            const key = try reader.int(u64);
            const width = try reader.int(u32);
            const height = try reader.int(u32);
            const format = try reader.enumeration(render.types.Texture.Format);
            const stride = try reader.int(u32);
            const revision = try reader.int(u64);
            const force_upload = try reader.boolean();
            const bytes = try reader.bytes();
            if (width == 0) return error.InvalidWire;
            if (width > 8192) return error.LimitExceeded;
            if (height > 8192) return error.LimitExceeded;
            if (height == 0) return error.InvalidWire;
            if (format == .depth24_plus) return error.InvalidWire;
            const row_bytes = @as(u64, width) * format.bytesPerPixel();
            const actual_stride: u64 = if (stride == 0) row_bytes else stride;
            if (actual_stride < row_bytes) return error.InvalidWire;
            const required = std.math.mul(u64, actual_stride, height - 1) catch return error.InvalidWire;
            if (required > bytes.len) return error.InvalidWire;
            if (row_bytes > bytes.len - required) return error.InvalidWire;
            return .{ .pixels = .{ .key = key, .width = width, .height = height, .format = format, .bytes_per_row = if (stride == 0) null else stride, .version = revision, .force_upload = force_upload, .data = try allocator.dupe(u8, bytes) } };
        },
        else => return error.InvalidWire,
    }
}

test "request round trip and every truncated prefix" {
    var state_bridge = try ui.StateBridge.init(std.testing.allocator);
    defer state_bridge.deinit();
    try state_bridge.write(u32, ui.StateBridge.key("counter"), 17);
    const state = try state_bridge.values(std.testing.allocator);
    defer std.testing.allocator.free(state);
    const request: Request = .{ .frame = .{ .input = .{ .pos = .{ 10, 20 } }, .now_ms = 7, .delta_ns = 16_000_000, .logical_extent = .{ .width = 300, .height = 200 }, .physical_extent = .{ .width = 600, .height = 400 }, .content_scale = 2 }, .state_scope = 99, .state = state };
    var writer: Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try encodeRequest(&writer, &request);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decodeRequest(arena.allocator(), writer.data.items);
    try std.testing.expectEqual(request.frame.logical_extent.width, decoded.frame.logical_extent.width);
    try std.testing.expectEqual(request.state_scope, decoded.state_scope);
    try state_bridge.load(decoded.state);
    try std.testing.expectEqual(@as(u32, 17), (try state_bridge.read(u32, ui.StateBridge.key("counter"))).?);
    for (0..writer.data.items.len) |length| {
        _ = arena.reset(.retain_capacity);
        if (decodeRequest(arena.allocator(), writer.data.items[0..length])) |_| return error.AcceptedTruncation else |_| {}
    }
}

fn testResponse(packet: render.Packet) Response {
    return .{
        .contribution = .{ .packet = packet },
        .dependencies = &.{.{ .domain = 4, .key = 5 }},
        .effects = .{ .clipboard_write = "copied" },
    };
}

test "response round trip, truncation, unsupported version and excessive counts" {
    const response = testResponse(.init(&.{}, &.{}, &.{}, &.{}, &.{}, &.{}, null));
    var writer: Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try encodeResponse(&writer, &response);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decodeResponse(arena.allocator(), writer.data.items);
    try std.testing.expectEqualStrings("copied", decoded.effects.clipboard_write.?);
    try std.testing.expectEqual(@as(u64, 4), decoded.dependencies[0].domain);
    try std.testing.expectEqual(@as(u64, 5), decoded.dependencies[0].key);
    for (0..writer.data.items.len) |length| {
        _ = arena.reset(.free_all);
        if (decodeResponse(arena.allocator(), writer.data.items[0..length])) |_| return error.TruncationAccepted else |_| {}
    }
    writer.data.items[0] = 99;
    try std.testing.expectError(error.UnsupportedVersion, decodeResponse(arena.allocator(), writer.data.items));
    var count_reader: Reader = .{ .data = &.{ 255, 255, 255, 255 } };
    try std.testing.expectError(error.LimitExceeded, readCount(&count_reader, 1));
    try std.testing.expectError(error.InvalidWire, validateRange(std.math.maxInt(u32), 2, 16));
    try std.testing.expectError(error.InvalidWire, validateRange(1, std.math.maxInt(u32), 16));
}

test "response rejects cyclic clipping and invalid draw references" {
    var node = render.Clip.Node.empty;
    node.parent = 1;
    const cyclic = testResponse(.init(&.{}, &.{}, &.{}, &.{}, &.{}, &.{ render.Clip.Node.empty, node }, null));
    var writer: Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try encodeResponse(&writer, &cyclic);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidWire, decodeResponse(arena.allocator(), writer.data.items));
    writer.data.clearRetainingCapacity();
    const invalid = testResponse(.init(&.{.{ .clip = .{}, .payload = .{ .instance = .{ .offset = 0, .count = 1, .texture = .atlas } } }}, &.{}, &.{}, &.{}, &.{}, &.{}, null));
    try encodeResponse(&writer, &invalid);
    try std.testing.expectError(error.InvalidWire, decodeResponse(arena.allocator(), writer.data.items));
}

test "pixel textures reject insufficient data and unknown resource tags" {
    var writer: Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try writeTexture(&writer, .{ .pixels = .{ .key = 1, .width = 2, .height = 2, .format = .rgba8, .bytes_per_row = null, .version = 0, .force_upload = false, .data = &.{0} } });
    var reader: Reader = .{ .data = writer.data.items };
    try std.testing.expectError(error.InvalidWire, readTexture(&reader, std.testing.allocator));
    var invalid: Reader = .{ .data = &.{ 99, 0, 0, 0 } };
    try std.testing.expectError(error.InvalidWire, readTexture(&invalid, std.testing.allocator));
}

test "glyph references reject missing atlas data and unbounded shader loops" {
    var text: render.types.SlugInstance = std.mem.zeroes(render.types.SlugInstance);
    var atlas: render.GlyphAtlas = .{ .id = 1, .revision = 1, .curve = &.{}, .band = &.{} };
    try std.testing.expectError(error.InvalidWire, validateGlyphs(std.testing.allocator, &atlas, &.{text}));
    var band: [32]u8 = @splat(0);
    std.mem.writeInt(u32, band[0..4], 4097, .little);
    atlas.band = &band;
    try std.testing.expectError(error.LimitExceeded, validateGlyphs(std.testing.allocator, &atlas, &.{text}));
    text.glyph[0] = @bitCast(@as(u32, render.GlyphAtlas.width));
    try std.testing.expectError(error.InvalidWire, validateGlyphs(std.testing.allocator, &atlas, &.{text}));
}
