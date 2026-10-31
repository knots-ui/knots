//! Borrowed glyph store snapshot: a u32 word buffer of glyph blobs and a slot table,
//! both bound as read-only storage buffers. Each GPU copy owns a GlyphAtlasCache.
const std = @import("std");
const GlyphAtlas = @This();

id: u32,
revision: u64,
/// Dirty ranges are relative to this previous emitted revision. A consumer that
/// missed it, or sees `full`, must replace its copy with the whole snapshot.
base_revision: u64 = 0,
full: bool = true,
words: []const u8,
table: []const u8,
words_dirty: Range = .{},
table_dirty: Range = .{},

pub const Range = struct { start: usize = 0, end: usize = 0 };

pub const word_bytes: u32 = 4;
pub const entry_bytes: u32 = @sizeOf(@import("render_types").GlyphEntry);
/// The minimum storage binding size WebGPU and Vulkan guarantee.
pub const plane_bytes_max: u32 = 128 * 1024 * 1024;
var next_id: std.atomic.Value(u32) = .init(1);

/// IDs never repeat, including when an allocator reuses a destroyed Context address.
pub fn allocateId() u32 {
    const id = next_id.fetchAdd(1, .monotonic);
    // Exhaustion is fatal: continuing after wrap could alias a live atlas.
    if (id == 0) @panic("Glyph atlas IDs exhausted");
    if (id == std.math.maxInt(u32)) @panic("Glyph atlas IDs exhausted");
    std.debug.assert(id > 0);
    std.debug.assert(id < std.math.maxInt(u32));
    return id;
}

pub fn validate(self: *const GlyphAtlas) void {
    std.debug.assert(self.id > 0);
    std.debug.assert(self.words.len > 0 and self.words.len <= plane_bytes_max);
    std.debug.assert(self.table.len > 0 and self.table.len <= plane_bytes_max);
    std.debug.assert(self.words.len % word_bytes == 0);
    std.debug.assert(self.table.len % entry_bytes == 0);
    std.debug.assert(self.words_dirty.start <= self.words_dirty.end and self.words_dirty.end <= self.words.len);
    std.debug.assert(self.table_dirty.start <= self.table_dirty.end and self.table_dirty.end <= self.table.len);
}
