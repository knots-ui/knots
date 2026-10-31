const std = @import("std");
const render = @import("render");

const GlyphAtlasCache = @This();

id: u32 = 0,
revision: u64 = 0,

/// Dirty ranges are valid only when this GPU copy contains the exact base.
pub fn canUploadDelta(self: *const GlyphAtlasCache, atlas: *const render.GlyphAtlas) bool {
    std.debug.assert(atlas.id > 0);
    if (atlas.full) return false;
    if (self.id == atlas.id) return self.revision == atlas.base_revision;
    return false;
}

/// The uploader copies selected bytes before returning. Any failure invalidates
/// the cache: partial writes or buffer replacement may have destroyed old data.
pub fn sync(self: *GlyphAtlasCache, atlas: *const render.GlyphAtlas, uploader: anytype, comptime upload: anytype) !void {
    atlas.validate();
    std.debug.assert(atlas.id > 0);
    if (self.id == atlas.id) {
        if (self.revision == atlas.revision) return;
    }
    errdefer self.* = .{};
    try upload(uploader, atlas, self.canUploadDelta(atlas));
    self.* = .{ .id = atlas.id, .revision = atlas.revision };
}
