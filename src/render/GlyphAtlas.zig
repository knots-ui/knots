//! Borrowed complete atlas, available even after dropped frames or device loss.
//! No acknowledgement mutates the producer. Each GPU atlas owns an GlyphAtlasCache.
const std = @import("std");
const GlyphAtlas = @This();

id: u32,
revision: u64,
/// Dirty ranges are relative to this previous emitted revision. A consumer that
/// missed it must upload the full snapshot instead.
base_revision: u64 = 0,
curve_row_start: u32 = 0,
band_row_start: u32 = 0,
curve: []const u8,
band: []const u8,

pub const width: u32 = 4096;
pub const texel_bytes: u32 = 16;
pub const row_bytes: u32 = width * texel_bytes;
pub const plane_bytes_max: u32 = width * row_bytes;
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
    std.debug.assert(self.curve.len <= plane_bytes_max);
    std.debug.assert(self.band.len <= plane_bytes_max);
    std.debug.assert(self.curve.len % texel_bytes == 0);
    std.debug.assert(self.band.len % texel_bytes == 0);
    std.debug.assert(self.curve_row_start <= std.math.divCeil(u64, self.curve.len, row_bytes) catch unreachable);
    std.debug.assert(self.band_row_start <= std.math.divCeil(u64, self.band.len, row_bytes) catch unreachable);
}
