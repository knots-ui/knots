const std = @import("std");
const FontProgram = @import("font/FontProgram.zig");
const Outline = @import("font/Outline.zig");
const GlyphStore = @import("GlyphStore.zig");
const TextLayout = @import("TextLayout.zig");
const curve = @import("curve.zig");
const glyph = @import("glyph.zig");
const shape = @import("shape/root.zig");
const itemize = @import("itemize.zig");
const unicode = @import("unicode/root.zig");
const ClockCache = @import("ClockCache.zig").ClockCache;

gpa: std.mem.Allocator,
faces: std.ArrayList(*Face),
families: std.ArrayList(Family),
/// Plans by face, script and feature shape. Evicted with the other caches, so plans used in
/// a frame stay valid until `endFrame`.
plans: ClockCache(*CachedPlan, PlanValue),
plan_serial: u64 = 0,
runs: std.ArrayList(itemize.Run),
glyph_store: GlyphStore,
evicted_glyphs: std.ArrayList(u64),
buffer: shape.Buffer,
shaped: std.ArrayList(shape.ShapedGlyph),
layouts: ClockCache(*TextLayout, LayoutValue),
/// Layouts of keyed requests, by key and style. Content is compared, not hashed, and an
/// edit rebuilds only the paragraphs it touches.
keyed: std.AutoArrayHashMapUnmanaged(u64, Keyed),
words: ClockCache([]shape.ShapedGlyph, WordValue),
key_bytes: std.ArrayList(u8),
word_key: std.ArrayList(u8),
itemize_scratch: itemize.Scratch,
line_break_scratch: unicode.linebreak.Scratch = .{},
frame: u32,
/// Cache counters since init, for tools and diagnostics.
stats: Stats = .{},

const TextSystem = @This();

pub const FaceId = TextLayout.FaceId;

pub const faces_max = 256;
pub const families_max = 64;
pub const chain_length_max = itemize.chain_length_max;
pub const layout_cache_bytes_default = 8 * 1024 * 1024;
pub const word_cache_bytes_default = 16 * 1024 * 1024;
pub const plan_cache_bytes_default = 4 * 1024 * 1024;
pub const tab_size_default = 4;

comptime {
    std.debug.assert(faces_max <= std.math.maxInt(FaceId) + 1);
    std.debug.assert(layout_cache_bytes_default > 0);
    std.debug.assert(families_max == 64 and chain_length_max == 16);
    std.debug.assert(word_cache_bytes_default == 16 * 1024 * 1024);
}

pub const Family = struct {
    name: []const u8,
    chain: Chain,
};

pub const Chain = struct {
    faces: [chain_length_max]FaceId = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Chain) []const FaceId {
        return self.faces[0..self.len];
    }
};

const ChainId = u16;
const default_chain: ChainId = 0xFFFF;
const face_chain_bit: ChainId = 0x8000;

pub const Stats = struct {
    word_hits: u64 = 0,
    word_misses: u64 = 0,
    layout_hits: u64 = 0,
    layout_builds: u64 = 0,
};

pub const FontSource = struct {
    name: []const u8,
    data: []const u8,
};

pub const Face = struct {
    name: []const u8,
    program: FontProgram,
    follow: shape.follow.Store,
    glyphs: std.AutoHashMapUnmanaged(u32, glyph.GlyphRecord) = .empty,

    pub fn unitsPerEm(self: *const Face) f32 {
        return @floatFromInt(self.program.units_per_em);
    }

    pub fn ascender(self: *const Face, size: f32) f32 {
        const ascender_em = @as(f32, @floatFromInt(self.program.metrics.ascender)) / self.unitsPerEm();
        return ascender_em * size;
    }

    pub fn lineHeight(self: *const Face, size: f32) f32 {
        const metrics = self.program.metrics;
        const units: i32 = @as(i32, metrics.ascender) - metrics.descender + metrics.line_gap;
        const line_height_em = @as(f32, @floatFromInt(units)) / self.unitsPerEm();
        return line_height_em * size;
    }
};

/// Overrides font, size or features for `[start, end)` of the request text.
pub const StyleRun = struct {
    start: u32,
    end: u32,
    font: ?[]const u8 = null,
    size: ?f32 = null,
    features: []const shape.Plan.Feature = &.{},
};

pub const Request = struct {
    text: []const u8,
    font: ?[]const u8 = null,
    size: f32,
    /// Global or ranged, with ranges in bytes of `text`.
    features: []const shape.Plan.Feature = &.{},
    runs: []const StyleRun = &.{},
    wrap_width: f32 = 0,
    tab_size: u8 = tab_size_default,
    key: ?u64 = null,
    revision: u32 = 0,
};

pub fn init(gpa: std.mem.Allocator, sources: []const FontSource) !TextSystem {
    if (sources.len == 0) {
        return error.EmptyFontSet;
    }
    var glyph_store = try GlyphStore.init(gpa);
    errdefer glyph_store.deinit();

    var self: TextSystem = .{
        .gpa = gpa,
        .faces = .empty,
        .families = .empty,
        .plans = .init(plan_cache_bytes_default),
        .runs = .empty,
        .glyph_store = glyph_store,
        .evicted_glyphs = .empty,
        .buffer = shape.Buffer.init(gpa),
        .shaped = .empty,
        .layouts = .init(layout_cache_bytes_default),
        .keyed = .empty,
        .words = .init(word_cache_bytes_default),
        .key_bytes = .empty,
        .word_key = .empty,
        .itemize_scratch = .{},
        .frame = 0,
    };
    errdefer self.deinitFaces();
    for (sources) |source| try self.addFace(source.name, source.data);
    return self;
}

pub fn deinit(self: *TextSystem) void {
    self.layouts.deinit(self.gpa);
    for (self.keyed.values()) |*entry| entry.deinit(self.gpa);
    self.keyed.deinit(self.gpa);
    self.words.deinit(self.gpa);
    self.key_bytes.deinit(self.gpa);
    self.word_key.deinit(self.gpa);
    self.itemize_scratch.deinit(self.gpa);
    self.line_break_scratch.deinit(self.gpa);
    self.plans.deinit(self.gpa);
    self.families.deinit(self.gpa);
    self.runs.deinit(self.gpa);
    self.deinitFaces();
    self.buffer.deinit();
    self.shaped.deinit(self.gpa);
    self.glyph_store.deinit();
    self.evicted_glyphs.deinit(self.gpa);
}

fn deinitFaces(self: *TextSystem) void {
    for (self.faces.items) |face| {
        face.follow.deinit(self.gpa);
        face.program.deinit();
        face.glyphs.deinit(self.gpa);
        self.gpa.destroy(face);
    }
    self.faces.deinit(self.gpa);
}

pub fn addFace(self: *TextSystem, name: []const u8, data: []const u8) !void {
    for (self.faces.items) |face| {
        if (std.mem.eql(u8, face.name, name)) {
            return error.DuplicateFont;
        }
    }
    if (self.faces.items.len >= faces_max) {
        return error.TooManyFonts;
    }
    const face = try self.gpa.create(Face);
    errdefer self.gpa.destroy(face);
    face.* = .{ .name = name, .program = try FontProgram.init(self.gpa, data, 0), .follow = undefined };
    errdefer face.program.deinit();
    face.follow = try shape.follow.Store.init(self.gpa, &face.program);
    errdefer face.follow.deinit(self.gpa);
    try self.faces.append(self.gpa, face);
}

/// A fallback chain of faces, tried in order for each cluster.
pub fn addFamily(self: *TextSystem, name: []const u8, face_names: []const []const u8) !void {
    if (face_names.len == 0 or face_names.len > chain_length_max) {
        return error.InvalidFamily;
    }
    if (self.families.items.len >= families_max) {
        return error.TooManyFamilies;
    }
    for (self.families.items) |family| {
        if (std.mem.eql(u8, family.name, name)) {
            return error.DuplicateFamily;
        }
    }
    var chain: Chain = .{};
    for (face_names) |face_name| {
        chain.faces[chain.len] = try self.faceId(face_name);
        chain.len += 1;
    }
    try self.families.append(self.gpa, .{ .name = name, .chain = chain });
}

fn chainId(self: *const TextSystem, name: ?[]const u8) !ChainId {
    const wanted = name orelse return default_chain;
    for (self.families.items, 0..) |family, index| {
        if (std.mem.eql(u8, family.name, wanted)) {
            return @intCast(index);
        }
    }
    return face_chain_bit | try self.faceId(wanted);
}

fn chainOf(self: *const TextSystem, id: ChainId) Chain {
    var chain: Chain = .{};
    if (id == default_chain) {
        for (self.faces.items[0..@min(self.faces.items.len, chain_length_max)], 0..) |_, index| {
            chain.faces[index] = @intCast(index);
            chain.len += 1;
        }
        return chain;
    }
    if (id & face_chain_bit != 0) {
        chain.faces[0] = id & ~face_chain_bit;
        chain.len = 1;
        return chain;
    }
    return self.families.items[id].chain;
}

const CachedPlan = struct {
    plan: shape.Plan,
    /// Never reused, unlike the plan's address, so word cache keys outlive eviction.
    serial: u64,
};

const PlanValue = struct {
    pub fn free(gpa: std.mem.Allocator, value: *CachedPlan) void {
        value.plan.deinit();
        gpa.destroy(value);
    }
    pub fn bytes(value: *CachedPlan) usize {
        return @sizeOf(CachedPlan) + value.plan.arena_state.queryCapacity();
    }
};

const plan_features_max = shape.Plan.ranged_features_max + 32;

/// A plan depends on the tags, values and rangedness of the features, not on the ranges.
fn planFor(self: *TextSystem, face_id: FaceId, script: unicode.Script, features: []const shape.Plan.Feature) !*const CachedPlan {
    if (features.len > plan_features_max) {
        return error.TooManyFeatures;
    }
    const Header = extern struct { face: u32, script: u32 };
    const header: Header = .{ .face = face_id, .script = @backingInt(script) };
    var key_buffer: [@sizeOf(Header) + plan_features_max * @sizeOf(shape.Plan.Feature)]u8 = undefined;
    var normalized: [plan_features_max]shape.Plan.Feature = undefined;
    for (features, normalized[0..features.len]) |feature, *entry| {
        entry.* = feature;
        if (!feature.isGlobal()) {
            entry.start = 0;
            entry.end = 1;
        }
    }
    const feature_bytes = std.mem.sliceAsBytes(normalized[0..features.len]);
    @memcpy(key_buffer[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(key_buffer[@sizeOf(Header)..][0..feature_bytes.len], feature_bytes);
    const key = key_buffer[0 .. @sizeOf(Header) + feature_bytes.len];
    if (self.plans.get(key, self.frame)) |cached| {
        return cached;
    }
    const cached = try self.gpa.create(CachedPlan);
    errdefer self.gpa.destroy(cached);
    const face = self.faceById(face_id);
    cached.* = .{
        .plan = try shape.Plan.init(self.gpa, &face.program, &face.follow, .{ .script = script, .features = normalized[0..features.len] }),
        .serial = self.plan_serial,
    };
    self.plan_serial += 1;
    return self.plans.put(self.gpa, key, cached, self.frame);
}

/// Whether two feature lists select the same plan.
fn samePlanFeatures(a: []const shape.Plan.Feature, b: []const shape.Plan.Feature) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |x, y| {
        if (x.tag != y.tag or x.value != y.value or x.isGlobal() != y.isGlobal()) {
            return false;
        }
    }
    return true;
}

pub fn faceId(self: *const TextSystem, name: ?[]const u8) !FaceId {
    const wanted = name orelse return 0;
    for (self.faces.items, 0..) |face, index| {
        if (std.mem.eql(u8, face.name, wanted)) {
            return @intCast(index);
        }
    }
    return error.UnknownFont;
}

pub fn faceById(self: *const TextSystem, id: FaceId) *Face {
    return self.faces.items[id];
}

pub fn lineHeight(self: *const TextSystem, font: ?[]const u8, size: f32) !f32 {
    try validateSize(size);
    const chain = self.chainOf(try self.chainId(font));
    return self.faceById(chain.faces[0]).lineHeight(size);
}

fn validateSize(size: f32) !void {
    if (!std.math.isFinite(size) or size < 0) {
        return error.InvalidPixelSize;
    }
}

/// The glyph's store slot, built on first use and kept while used every `GlyphStore.eviction_age_frames`.
pub fn glyphRecord(self: *TextSystem, face_id: FaceId, glyph_id: u32) !glyph.GlyphRecord {
    const target = self.faceById(face_id);
    if (target.glyphs.get(glyph_id)) |record| {
        self.glyph_store.touch(record.slot);
        return record;
    }
    const record = try self.buildGlyph(target, glyph_id, (@as(u64, face_id) << 32) | glyph_id);
    try target.glyphs.put(self.gpa, glyph_id, record);
    return record;
}

fn buildGlyph(self: *TextSystem, target: *Face, glyph_id: u32, owner: u64) !glyph.GlyphRecord {
    var vertices: std.ArrayList(Outline.Vertex) = .empty;
    defer vertices.deinit(self.gpa);
    try target.program.outline.glyph(self.gpa, glyph_id, &vertices);
    const curves = try curve.decomposeVertices(self.gpa, vertices.items, target.unitsPerEm());
    defer self.gpa.free(curves);
    const added = try self.glyph_store.add(curves, owner);
    const bounds = added.entry.bounds;
    return .{ .slot = added.slot, .bounds_em_min = .{ bounds[0], bounds[1] }, .bounds_em_max = .{ bounds[2], bounds[3] } };
}

/// Glyph store slots for every glyph of `text_layout`, building missing glyphs. Slots stay
/// valid until the store evicts, so painting indexes them instead of looking glyphs up.
pub fn resolveSlots(self: *TextSystem, text_layout: *const TextLayout) ![]const u32 {
    const target: *TextLayout = @constCast(text_layout);
    if (target.slot_generation == self.glyph_store.generation and target.slots.len == target.glyphs.ids.len) {
        return target.slots;
    }
    if (target.slots.len != target.glyphs.ids.len) {
        self.gpa.free(target.slots);
        target.slots = &.{};
        target.slots = try self.gpa.alloc(u32, target.glyphs.ids.len);
    }
    for (target.runs) |run| {
        const colr = &self.faceById(run.face).program.colr;
        for (run.glyph_start..run.glyph_end) |index| {
            const id = target.glyphs.ids[index];
            if (colr.layers(id).count > 0) {
                target.slots[index] = TextLayout.layered_slot;
                continue;
            }
            target.slots[index] = (try self.glyphRecord(run.face, id)).slot;
        }
    }
    // Building glyphs can evict, which bumps the generation: resolve again next time if so.
    target.slot_generation = self.glyph_store.generation;
    return target.slots;
}

pub fn layout(self: *TextSystem, request: Request) !*const TextLayout {
    try validateSize(request.size);
    const chain_id = try self.chainId(request.font);
    if (request.key) |key| {
        return self.keyedLayout(key, chain_id, request);
    }
    const header: LayoutKey = .{
        .chain = chain_id,
        .size = @bitCast(request.size),
        .wrap = @bitCast(@max(request.wrap_width, 0)),
        .tab_size = request.tab_size,
        .has_key = request.key != null,
        .key = request.key orelse 0,
        .revision = request.revision,
    };
    self.key_bytes.clearRetainingCapacity();
    try self.key_bytes.appendSlice(self.gpa, std.mem.asBytes(&header));
    try self.appendStyleKey(request, .all);
    try self.key_bytes.appendSlice(self.gpa, request.text);
    if (self.layouts.get(self.key_bytes.items, self.frame)) |cached| {
        self.stats.layout_hits += 1;
        return cached;
    }
    self.stats.layout_builds += 1;
    const built = try self.build(self.chainOf(chain_id), request);
    return self.layouts.put(self.gpa, self.key_bytes.items, built, self.frame);
}

/// Frames a keyed layout survives without being requested.
pub const keyed_age_frames = 2;

const Keyed = struct {
    layout: *TextLayout,
    /// The request's style without ranged features, compared on lookup so a hash collision can't return another style.
    style: []u8,
    /// Features the layout was built with.
    features: []shape.Plan.Feature,
    frame: u32,

    fn deinit(self: *Keyed, gpa: std.mem.Allocator) void {
        freeLayout(gpa, self.layout);
        gpa.free(self.style);
        gpa.free(self.features);
    }
};

fn keyedLayout(self: *TextSystem, key: u64, chain_id: ChainId, request: Request) !*const TextLayout {
    const header: LayoutKey = .{
        .chain = chain_id,
        .size = @bitCast(request.size),
        .wrap = @bitCast(@max(request.wrap_width, 0)),
        .tab_size = request.tab_size,
        .has_key = true,
        .key = key,
        .revision = request.revision,
    };
    self.key_bytes.clearRetainingCapacity();
    try self.key_bytes.appendSlice(self.gpa, std.mem.asBytes(&header));
    try self.appendStyleKey(request, .global_only);
    const style = self.key_bytes.items;
    const entry = try self.keyed.getOrPut(self.gpa, std.hash.Wyhash.hash(0, style));
    if (entry.found_existing and std.mem.eql(u8, entry.value_ptr.style, style)) {
        const keyed = entry.value_ptr;
        const old = keyed.layout;
        keyed.frame = self.frame;
        const same_features = std.mem.eql(u8, std.mem.sliceAsBytes(keyed.features), std.mem.sliceAsBytes(request.features));
        if (same_features and std.mem.eql(u8, old.text, request.text)) {
            self.stats.layout_hits += 1;
            return old;
        }
        self.stats.layout_builds += 1;
        // Plans differ between feature shapes, so paragraphs are reused only within one.
        const reusable = request.runs.len == 0 and samePlanFeatures(keyed.features, request.features);
        var reuse: ?Reuse = null;
        if (reusable) {
            reuse = Reuse.init(old, keyed.features, request.text);
        }
        const built = try self.buildReusing(self.chainOf(chain_id), request, reuse);
        errdefer freeLayout(self.gpa, built);
        if (!same_features) {
            const owned = try self.gpa.dupe(shape.Plan.Feature, request.features);
            self.gpa.free(keyed.features);
            keyed.features = owned;
        }
        freeLayout(self.gpa, old);
        keyed.layout = built;
        return built;
    }
    if (entry.found_existing) {
        entry.value_ptr.deinit(self.gpa);
    }
    errdefer _ = self.keyed.swapRemove(entry.key_ptr.*);
    const owned_style = try self.gpa.dupe(u8, style);
    errdefer self.gpa.free(owned_style);
    const features = try self.gpa.dupe(shape.Plan.Feature, request.features);
    errdefer self.gpa.free(features);
    self.stats.layout_builds += 1;
    const built = try self.build(self.chainOf(chain_id), request);
    entry.value_ptr.* = .{ .layout = built, .style = owned_style, .features = features, .frame = self.frame };
    return built;
}

fn appendStyleKey(self: *TextSystem, request: Request, features: enum { all, global_only }) !void {
    const gpa = self.gpa;
    const counts = [2]u32{ @intCast(request.features.len), @intCast(request.runs.len) };
    switch (features) {
        .all => {
            try self.key_bytes.appendSlice(gpa, std.mem.asBytes(&counts));
            try self.key_bytes.appendSlice(gpa, std.mem.sliceAsBytes(request.features));
        },
        .global_only => {
            try self.key_bytes.appendSlice(gpa, std.mem.asBytes(&counts[1]));
            for (request.features) |feature| {
                if (feature.isGlobal()) {
                    try self.key_bytes.appendSlice(gpa, std.mem.asBytes(&feature));
                }
            }
        },
    }
    for (request.runs) |run| {
        const size: u32 = @bitCast(run.size orelse -1);
        const chain: u16 = switch (run.font == null) {
            true => 0xFFFE,
            false => try self.chainId(run.font),
        };
        const fixed = [5]u32{ run.start, run.end, size, chain, @intCast(run.features.len) };
        try self.key_bytes.appendSlice(gpa, std.mem.asBytes(&fixed));
        try self.key_bytes.appendSlice(gpa, std.mem.sliceAsBytes(run.features));
    }
}

pub fn endFrame(self: *TextSystem) void {
    self.layouts.evict(self.gpa, self.frame);
    var index: u32 = 0;
    while (index < self.keyed.count()) {
        const values = self.keyed.values();
        if (self.frame -% values[index].frame < keyed_age_frames) {
            index += 1;
            continue;
        }
        values[index].deinit(self.gpa);
        self.keyed.swapRemoveAt(index);
    }
    self.words.evict(self.gpa, self.frame);
    self.plans.evict(self.gpa, self.frame);
    self.frame +%= 1;
    // Best effort: without memory to evict, the store stays over budget for a frame.
    self.glyph_store.endFrame(&self.evicted_glyphs) catch return;
    for (self.evicted_glyphs.items) |owner| {
        const target = self.faceById(@intCast(owner >> 32));
        _ = target.glyphs.remove(@truncate(owner));
    }
}

pub fn setCacheBudgets(self: *TextSystem, layout_bytes: usize, word_bytes: usize, plan_bytes: usize) void {
    self.layouts.budget = layout_bytes;
    self.words.budget = word_bytes;
    self.plans.budget = plan_bytes;
}

const LayoutKey = extern struct {
    key: u64,
    chain: u16,
    tab_size: u8,
    has_key: bool,
    size: u32,
    wrap: u32,
    revision: u32,
};

const LayoutValue = struct {
    pub fn free(gpa: std.mem.Allocator, value: *TextLayout) void {
        freeLayout(gpa, value);
    }
    pub fn bytes(value: *TextLayout) usize {
        return layoutBytes(value);
    }
};

const WordValue = struct {
    pub fn free(gpa: std.mem.Allocator, value: []shape.ShapedGlyph) void {
        gpa.free(value);
    }
    pub fn bytes(value: []shape.ShapedGlyph) usize {
        return value.len * @sizeOf(shape.ShapedGlyph);
    }
};

/// Shapes `text` with `plan`, through the word cache.
fn shapeCached(self: *TextSystem, face_id: FaceId, cached_plan: *const CachedPlan, text: []const u8, ranges: []const shape.Plan.Feature) ![]const shape.ShapedGlyph {
    var key_buffer: [12]u8 = undefined;
    std.mem.writeInt(u64, key_buffer[0..8], cached_plan.serial, .little);
    std.mem.writeInt(u32, key_buffer[8..12], @intCast(ranges.len), .little);
    const key = &self.word_key;
    key.clearRetainingCapacity();
    try key.appendSlice(self.gpa, &key_buffer);
    try key.appendSlice(self.gpa, std.mem.sliceAsBytes(ranges));
    try key.appendSlice(self.gpa, text);
    if (self.words.get(key.items, self.frame)) |cached| {
        self.stats.word_hits += 1;
        return cached;
    }
    self.stats.word_misses += 1;
    self.shaped.clearRetainingCapacity();
    const program = &self.faceById(face_id).program;
    try shape.shaper.shapeRanged(&self.buffer, program, &cached_plan.plan, text, ranges, self.gpa, &self.shaped);
    const owned = try self.gpa.dupe(shape.ShapedGlyph, self.shaped.items);
    return self.words.put(self.gpa, key.items, owned, self.frame);
}

/// End of the word or run of spaces at `start`, for fonts whose space glyph takes part in no
/// lookup. A run of spaces keeps a following mark, which continues the last space's cluster.
pub fn wordEnd(text: []const u8, start: usize, end: usize) usize {
    var position = start + 1;
    var spaces = text[start] == ' ';
    while (position < end) : (position += 1) {
        if ((text[position] == ' ') == spaces) {
            continue;
        }
        if (!spaces or !unicode.continuesAfter(text, position - 1, position)) {
            break;
        }
        spaces = false;
    }
    return position;
}

fn build(self: *TextSystem, chain: Chain, request: Request) !*TextLayout {
    return self.buildReusing(chain, request, null);
}

/// Builds a layout, copying paragraphs `reuse` shows are unchanged.
fn buildReusing(self: *TextSystem, chain: Chain, request: Request, reuse: ?Reuse) !*TextLayout {
    var builder: LayoutBuilder = .{
        .system = self,
        .request = request,
        .chain = chain,
        .primary = self.faceById(chain.faces[0]),
        .text = request.text,
        .wrap_width = @max(request.wrap_width, 0),
    };
    defer builder.deinit();
    builder.reuse = reuse;
    return builder.run();
}

/// The bytes an edit left unchanged. A paragraph wholly inside them keeps its layout.
const Reuse = struct {
    old: *const TextLayout,
    /// Features `old` was built with.
    old_features: []const shape.Plan.Feature,
    /// New bytes before this offset equal the old text's.
    prefix: usize,
    /// New bytes from this offset on equal the old text's, shifted by `shift`.
    suffix_start: usize,
    shift: i64,

    fn init(old: *const TextLayout, old_features: []const shape.Plan.Feature, text: []const u8) Reuse {
        const prefix = std.mem.indexOfDiff(u8, old.text, text) orelse @min(old.text.len, text.len);
        var suffix: usize = 0;
        const suffix_max = @min(old.text.len, text.len) - prefix;
        while (suffix < suffix_max and old.text[old.text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;
        return .{ .old = old, .old_features = old_features, .prefix = prefix, .suffix_start = text.len - suffix, .shift = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old.text.len)) };
    }

    /// Where the new paragraph `[start, end)` starts in the old text, when its bytes and the
    /// newlines around it are unchanged.
    fn oldStart(self: Reuse, start: usize, end: usize, text_len: usize) ?u32 {
        const last = end == text_len;
        // Before the edit: the paragraph and its terminating newline precede the first change.
        if (end < self.prefix or (last and end <= self.prefix and self.old.text.len == text_len)) {
            return @intCast(start);
        }
        // After the edit: the newline before the paragraph follows the last change.
        if (start == 0 or start - 1 < self.suffix_start) {
            return null;
        }
        return @intCast(@as(i64, @intCast(start)) - self.shift);
    }
};

const Style = struct {
    chain: Chain,
    size: f32,
    /// Request and run features, valid until the next `styleAt`.
    features: []const shape.Plan.Feature,
    run_features: []const shape.Plan.Feature,
};

const LayoutBuilder = struct {
    system: *TextSystem,
    request: Request,
    chain: Chain,
    primary: *Face,
    text: []const u8,
    wrap_width: f32,
    ids: std.ArrayList(u32) = .empty,
    xs: std.ArrayList(f64) = .empty,
    advances: std.ArrayList(f32) = .empty,
    x_offsets: std.ArrayList(f32) = .empty,
    y_offsets: std.ArrayList(f32) = .empty,
    clusters: std.ArrayList(u32) = .empty,
    flags: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(TextLayout.Line) = .empty,
    runs: std.ArrayList(TextLayout.Run) = .empty,
    items: std.ArrayList(itemize.Run) = .empty,
    ranges: std.ArrayList(shape.Plan.Feature) = .empty,
    features: std.ArrayList(shape.Plan.Feature) = .empty,
    carets: std.ArrayList(TextLayout.Caret) = .empty,
    caret_offsets: std.ArrayList(f32) = .empty,
    /// UAX #14 opportunities of the current paragraph, by byte from `paragraph_start`.
    breaks: std.ArrayList(unicode.linebreak.Break) = .empty,
    paragraph_start: u32 = 0,
    reuse: ?Reuse = null,
    width: f32 = 0,
    y: f32 = 0,
    uniform: bool = true,

    fn deinit(self: *LayoutBuilder) void {
        const gpa = self.system.gpa;
        self.ids.deinit(gpa);
        self.xs.deinit(gpa);
        self.advances.deinit(gpa);
        self.x_offsets.deinit(gpa);
        self.y_offsets.deinit(gpa);
        self.clusters.deinit(gpa);
        self.flags.deinit(gpa);
        self.lines.deinit(gpa);
        self.runs.deinit(gpa);
        self.items.deinit(gpa);
        self.ranges.deinit(gpa);
        self.features.deinit(gpa);
        self.carets.deinit(gpa);
        self.caret_offsets.deinit(gpa);
        self.breaks.deinit(gpa);
    }

    fn run(self: *LayoutBuilder) !*TextLayout {
        const gpa = self.system.gpa;
        const expected = self.text.len + 1;
        try self.ids.ensureTotalCapacity(gpa, expected);
        try self.xs.ensureTotalCapacity(gpa, expected);
        try self.advances.ensureTotalCapacity(gpa, expected);
        try self.x_offsets.ensureTotalCapacity(gpa, expected);
        try self.y_offsets.ensureTotalCapacity(gpa, expected);
        try self.clusters.ensureTotalCapacity(gpa, expected);
        try self.flags.ensureTotalCapacity(gpa, expected);
        if (self.text.len > 0) {
            var start: usize = 0;
            while (true) {
                const end = std.mem.findScalarPos(u8, self.text, start, '\n') orelse self.text.len;
                var copied = false;
                if (self.reuse) |reuse| {
                    copied = try self.copyParagraph(reuse, start, end);
                }
                if (!copied) {
                    try self.paragraph(@intCast(start), @intCast(end));
                }
                if (end == self.text.len) {
                    break;
                }
                start = end + 1;
            }
        }
        try self.collectCarets();
        return self.finish();
    }

    /// Appends the old layout's lines for the paragraph at `[start, end)`, when its bytes are unchanged.
    fn copyParagraph(self: *LayoutBuilder, reuse: Reuse, start: usize, end: usize) !bool {
        const old_start = reuse.oldStart(start, end, self.text.len) orelse return false;
        const old = reuse.old;
        const old_end = old_start + @as(u32, @intCast(end - start));
        if (old_end > old.text.len) {
            return false;
        }
        if (old_end < old.text.len and old.text[old_end] != '\n') {
            return false;
        }
        const first = old.lineForByte(old_start);
        if (first >= old.lines.len or old.lines[first].byte_start != old_start) {
            return false;
        }
        var last = first;
        while (last < old.lines.len and old.lines[last].byte_end < old_end) last += 1;
        if (last >= old.lines.len or old.lines[last].byte_end != old_end) {
            return false;
        }
        last += 1;
        const glyph_start = old.lines[first].glyph_start;
        const glyph_end = old.lines[last - 1].glyph_end;
        const shift: i64 = @as(i64, @intCast(start)) - @as(i64, old_start);
        if (!sameRangesOver(reuse.old_features, old_start, old_end, self.request.features, @intCast(start), @intCast(end))) {
            return false;
        }
        const base = self.glyphCount();
        const gpa = self.system.gpa;
        const glyphs = old.glyphs;
        try self.ids.appendSlice(gpa, glyphs.ids[glyph_start..glyph_end]);
        try self.xs.appendSlice(gpa, glyphs.x[glyph_start..glyph_end]);
        try self.advances.appendSlice(gpa, glyphs.advance[glyph_start..glyph_end]);
        try self.x_offsets.appendSlice(gpa, glyphs.x_offset[glyph_start..glyph_end]);
        try self.y_offsets.appendSlice(gpa, glyphs.y_offset[glyph_start..glyph_end]);
        try self.flags.appendSlice(gpa, glyphs.flags[glyph_start..glyph_end]);
        try self.clusters.ensureUnusedCapacity(gpa, glyph_end - glyph_start);
        for (glyphs.cluster[glyph_start..glyph_end]) |cluster| self.clusters.appendAssumeCapacity(@intCast(@as(i64, cluster) + shift));
        for (old.runs) |old_run| {
            const run_start = @max(old_run.glyph_start, glyph_start);
            const run_end = @min(old_run.glyph_end, glyph_end);
            if (run_start >= run_end) {
                continue;
            }
            try self.appendRunRange(base + (run_start - glyph_start), base + (run_end - glyph_start), old_run.face, old_run.size);
        }
        for (old.lines[first..last]) |line| {
            const byte_start: u32 = @intCast(@as(i64, line.byte_start) + shift);
            const byte_end: u32 = @intCast(@as(i64, line.byte_end) + shift);
            try self.appendLine(base + (line.glyph_start - glyph_start), base + (line.glyph_end - glyph_start), byte_start, byte_end);
        }
        return true;
    }

    fn glyphCount(self: *const LayoutBuilder) u32 {
        return @intCast(self.ids.items.len);
    }

    fn truncate(self: *LayoutBuilder, count: u32) void {
        self.ids.shrinkRetainingCapacity(count);
        self.xs.shrinkRetainingCapacity(count);
        self.advances.shrinkRetainingCapacity(count);
        self.x_offsets.shrinkRetainingCapacity(count);
        self.y_offsets.shrinkRetainingCapacity(count);
        self.clusters.shrinkRetainingCapacity(count);
        self.flags.shrinkRetainingCapacity(count);
        while (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.glyph_start >= count) {
                _ = self.runs.pop();
                continue;
            }
            last.glyph_end = @min(last.glyph_end, count);
            break;
        }
    }

    fn paragraph(self: *LayoutBuilder, start: u32, end: u32) !void {
        const system = self.system;
        try self.breaks.resize(system.gpa, end - start);
        try unicode.linebreak.opportunities(system.gpa, &system.line_break_scratch, self.text[start..end], self.breaks.items);
        self.paragraph_start = start;
        var position = start;
        while (true) {
            const base = self.glyphCount();
            try self.shapeSpan(position, end);
            var cursor = base;
            var line_byte = position;
            while (true) {
                const found = self.nextBreak(cursor) orelse {
                    try self.appendLine(cursor, self.glyphCount(), line_byte, end);
                    return;
                };
                if (found.next < self.glyphCount() and self.flags.items[found.next] & shape.shaper.unsafe_to_break != 0) {
                    const next_byte = self.clusters.items[found.next];
                    self.truncate(cursor);
                    try self.shapeSpan(line_byte, found.byte_end);
                    try self.appendLine(cursor, self.glyphCount(), line_byte, found.byte_end);
                    position = next_byte;
                    break;
                }
                try self.appendLine(cursor, found.line_end, line_byte, found.byte_end);
                cursor = found.next;
                line_byte = self.clusters.items[found.next];
            }
        }
    }

    const Break = struct {
        line_end: u32,
        next: u32,
        byte_end: u32,
    };

    /// Whitespace that hangs past the end of a line instead of counting toward its width.
    fn isBlank(self: *const LayoutBuilder, glyph_index: u32) bool {
        const byte = self.clusters.items[glyph_index];
        return switch (unicode.decodeUtf8(self.text, byte).codepoint) {
            ' ', '\t', 0x0B, 0x0C, '\r', 0x85, 0x2028, 0x2029 => true,
            else => false,
        };
    }

    fn spanWidth(self: *const LayoutBuilder, first: u32, end: u32) f64 {
        if (first == end) {
            return 0;
        }
        return self.xs.items[end - 1] + self.advances.items[end - 1] - self.xs.items[first];
    }

    /// The line break opportunity before glyph `index`: only between clusters.
    fn breakBefore(self: *const LayoutBuilder, index: u32) unicode.linebreak.Break {
        const clusters = self.clusters.items;
        if (index == 0 or clusters[index] == clusters[index - 1]) {
            return .none;
        }
        return self.breaks.items[clusters[index] - self.paragraph_start];
    }

    /// Ends a line at glyph `next`, leaving trailing whitespace out of it.
    fn breakAt(self: *const LayoutBuilder, line_start: u32, next: u32) Break {
        var line_end = next;
        while (line_end > line_start and self.isBlank(line_end - 1)) {
            line_end -= 1;
        }
        return .{ .line_end = line_end, .next = next, .byte_end = self.clusters.items[line_end] };
    }

    fn nextBreak(self: *const LayoutBuilder, line_start: u32) ?Break {
        const limit: f64 = self.wrap_width;
        const glyph_end = self.glyphCount();
        var last_break: ?u32 = null;
        var index = line_start;
        while (index < glyph_end) : (index += 1) {
            if (index > line_start) {
                switch (self.breakBefore(index)) {
                    .mandatory => return self.breakAt(line_start, index),
                    .allowed => last_break = index,
                    .none => {},
                }
            }
            if (self.wrap_width <= 0 or self.isBlank(index) or self.spanWidth(line_start, index + 1) <= limit) {
                continue;
            }
            if (last_break) |break_index| {
                return self.breakAt(line_start, break_index);
            }
            // No opportunity fits: break at the cluster boundary nearest the overflow.
            var cluster_start = index;
            while (cluster_start > line_start and self.clusters.items[cluster_start] == self.clusters.items[cluster_start - 1]) {
                cluster_start -= 1;
            }
            if (cluster_start > line_start) {
                return .{ .line_end = cluster_start, .next = cluster_start, .byte_end = self.clusters.items[cluster_start] };
            }
            var next = index + 1;
            while (next < glyph_end and self.clusters.items[next] == self.clusters.items[next - 1]) {
                next += 1;
            }
            if (next >= glyph_end) {
                return null;
            }
            return .{ .line_end = next, .next = next, .byte_end = self.clusters.items[next] };
        }
        return null;
    }

    /// The style at `byte` and where it ends. Later runs win where runs overlap.
    fn styleAt(self: *LayoutBuilder, byte: u32, limit: u32) !struct { Style, u32 } {
        var end = limit;
        var chosen: ?StyleRun = null;
        for (self.request.runs) |style_run| {
            if (style_run.start > byte) {
                end = @min(end, style_run.start);
                continue;
            }
            if (style_run.end <= byte) {
                continue;
            }
            chosen = style_run;
        }
        if (chosen) |style_run| {
            end = @min(end, style_run.end);
        }
        for (self.request.runs) |style_run| {
            if (style_run.end > byte and style_run.end < end) {
                end = style_run.end;
            }
        }
        const system = self.system;
        var style: Style = .{ .chain = self.chain, .size = self.request.size, .features = &.{}, .run_features = &.{} };
        self.features.clearRetainingCapacity();
        try self.features.appendSlice(system.gpa, self.request.features);
        if (chosen) |style_run| {
            if (style_run.font != null) {
                style.chain = system.chainOf(try system.chainId(style_run.font));
            }
            if (style_run.size) |size| {
                style.size = size;
            }
            try self.features.appendSlice(system.gpa, style_run.features);
            style.run_features = style_run.features;
        }
        style.features = self.features.items;
        return .{ style, @max(end, byte + 1) };
    }

    fn shapeSpan(self: *LayoutBuilder, start: u32, end: u32) !void {
        var pen: f64 = 0;
        var position = start;
        while (position < end) {
            const tab = std.mem.findScalarPos(u8, self.text[0..end], position, '\t') orelse end;
            if (tab == position) {
                const style, _ = try self.styleAt(position, end);
                pen = try self.appendTab(@intCast(tab), pen, style);
                position += 1;
                continue;
            }
            const style, const style_end = try self.styleAt(position, @intCast(tab));
            pen = try self.shapeItems(position, style_end, pen, style);
            position = style_end;
        }
    }

    fn appendTab(self: *LayoutBuilder, byte: u32, pen: f64, style: Style) !f64 {
        const face_id = style.chain.faces[0];
        const face = self.system.faceById(face_id);
        const program = &face.program;
        const scale = style.size / face.unitsPerEm();
        const space = program.space_glyph;
        const stop: f64 = @as(f64, @floatFromInt(program.advance(space))) * scale * @as(f64, @floatFromInt(@max(self.request.tab_size, 1)));
        var advance: f64 = stop;
        if (stop > 0) {
            advance = (@floor(pen / stop) + 1) * stop - pen;
        }
        const glyph_start = self.glyphCount();
        try self.appendGlyph(.{ .id = space, .x = pen, .advance = @floatCast(advance), .cluster = byte });
        try self.appendRun(glyph_start, face_id, style.size);
        return pen + advance;
    }

    const Appended = struct { id: u32, x: f64, advance: f32, x_offset: f32 = 0, y_offset: f32 = 0, cluster: u32, flags: u8 = 0 };

    fn appendGlyph(self: *LayoutBuilder, value: Appended) !void {
        const gpa = self.system.gpa;
        try self.ids.append(gpa, value.id);
        try self.xs.append(gpa, value.x);
        try self.advances.append(gpa, value.advance);
        try self.x_offsets.append(gpa, value.x_offset);
        try self.y_offsets.append(gpa, value.y_offset);
        try self.clusters.append(gpa, value.cluster);
        try self.flags.append(gpa, value.flags);
    }

    fn shapeItems(self: *LayoutBuilder, start: u32, end: u32, pen_start: f64, style: Style) !f64 {
        if (start == end) {
            return pen_start;
        }
        const system = self.system;
        const gpa = system.gpa;
        var programs: [chain_length_max]*const FontProgram = undefined;
        for (style.chain.slice(), 0..) |face_id, index| programs[index] = &system.faceById(face_id).program;
        self.items.clearRetainingCapacity();
        try itemize.itemizeWith(gpa, &system.itemize_scratch, self.text[start..end], programs[0..style.chain.len], &self.items);
        var pen = pen_start;
        for (self.items.items) |item| {
            const face_id = style.chain.faces[item.face];
            const face = system.faceById(face_id);
            const plan = try system.planFor(face_id, item.script, style.features);
            const glyph_start = self.glyphCount();
            pen = try self.shapeWords(face_id, plan, start + item.start, start + item.end, pen, style.size / face.unitsPerEm());
            try self.appendRun(glyph_start, face_id, style.size);
        }
        return pen;
    }

    fn rangesFor(self: *LayoutBuilder, start: u32, end: u32) ![]const shape.Plan.Feature {
        self.ranges.clearRetainingCapacity();
        for (self.request.features) |feature| {
            if (feature.isGlobal() or feature.end <= start or feature.start >= end) {
                continue;
            }
            var shifted = feature;
            shifted.start = @max(feature.start, start) - start;
            shifted.end = @min(feature.end, end) - start;
            try self.ranges.append(self.system.gpa, shifted);
        }
        return self.ranges.items;
    }

    fn shapeWords(self: *LayoutBuilder, face_id: FaceId, plan: *const CachedPlan, start: u32, end: u32, pen_start: f64, scale: f32) !f64 {
        if (plan.plan.space_participates) {
            const glyphs = try self.system.shapeCached(face_id, plan, self.text[start..end], try self.rangesFor(start, end));
            return self.appendShaped(glyphs, start, pen_start, scale);
        }
        var pen = pen_start;
        var segment = start;
        while (segment < end) {
            const segment_end: u32 = @intCast(wordEnd(self.text, segment, end));
            const glyphs = try self.system.shapeCached(face_id, plan, self.text[segment..segment_end], try self.rangesFor(segment, segment_end));
            pen = try self.appendShaped(glyphs, segment, pen, scale);
            segment = segment_end;
        }
        return pen;
    }

    fn appendRun(self: *LayoutBuilder, glyph_start: u32, face_id: FaceId, size: f32) !void {
        return self.appendRunRange(glyph_start, self.glyphCount(), face_id, size);
    }

    /// Adds glyphs `[glyph_start, glyph_end)` to the runs, extending the last run when it matches.
    fn appendRunRange(self: *LayoutBuilder, glyph_start: u32, glyph_end: u32, face_id: FaceId, size: f32) !void {
        if (glyph_end == glyph_start) {
            return;
        }
        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.face == face_id and last.size == size and last.glyph_end == glyph_start) {
                last.glyph_end = glyph_end;
                return;
            }
        }
        try self.runs.append(self.system.gpa, .{ .glyph_start = glyph_start, .glyph_end = glyph_end, .face = face_id, .size = size });
    }

    fn appendShaped(self: *LayoutBuilder, shaped_glyphs: []const shape.ShapedGlyph, byte_offset: u32, pen_start: f64, scale: f32) !f64 {
        const gpa = self.system.gpa;
        const count = shaped_glyphs.len;
        try self.ids.ensureUnusedCapacity(gpa, count);
        try self.xs.ensureUnusedCapacity(gpa, count);
        try self.advances.ensureUnusedCapacity(gpa, count);
        try self.x_offsets.ensureUnusedCapacity(gpa, count);
        try self.y_offsets.ensureUnusedCapacity(gpa, count);
        try self.clusters.ensureUnusedCapacity(gpa, count);
        try self.flags.ensureUnusedCapacity(gpa, count);
        var pen = pen_start;
        for (shaped_glyphs) |shaped| {
            const advance = @as(f32, @floatFromInt(shaped.x_advance)) * scale;
            self.ids.appendAssumeCapacity(shaped.glyph);
            self.xs.appendAssumeCapacity(pen);
            self.advances.appendAssumeCapacity(advance);
            self.x_offsets.appendAssumeCapacity(@as(f32, @floatFromInt(shaped.x_offset)) * scale);
            self.y_offsets.appendAssumeCapacity(@as(f32, @floatFromInt(shaped.y_offset)) * scale);
            self.clusters.appendAssumeCapacity(byte_offset + shaped.cluster);
            self.flags.appendAssumeCapacity(shaped.flags);
            pen += advance;
        }
        return pen;
    }

    const Metrics = struct { ascender: f32, height: f32 };

    fn lineMetrics(self: *const LayoutBuilder, glyph_start: u32, glyph_end: u32) Metrics {
        var metrics: Metrics = .{ .ascender = self.primary.ascender(self.request.size), .height = self.primary.lineHeight(self.request.size) };
        if (glyph_end == glyph_start) {
            return metrics;
        }
        if (self.uniformLine(glyph_start, glyph_end)) {
            return metrics;
        }
        metrics = .{ .ascender = 0, .height = 0 };
        var descent: f32 = 0;
        for (self.runs.items) |item| {
            if (item.glyph_end <= glyph_start or item.glyph_start >= glyph_end) {
                continue;
            }
            const face = self.system.faceById(item.face);
            const ascender = face.ascender(item.size);
            metrics.ascender = @max(metrics.ascender, ascender);
            descent = @max(descent, face.lineHeight(item.size) - ascender);
        }
        metrics.height = metrics.ascender + descent;
        return metrics;
    }

    fn uniformLine(self: *const LayoutBuilder, glyph_start: u32, glyph_end: u32) bool {
        for (self.runs.items) |item| {
            if (item.glyph_end <= glyph_start or item.glyph_start >= glyph_end) {
                continue;
            }
            const face = self.system.faceById(item.face);
            if (face.ascender(item.size) != self.primary.ascender(self.request.size)) {
                return false;
            }
            if (face.lineHeight(item.size) != self.primary.lineHeight(self.request.size)) {
                return false;
            }
        }
        return true;
    }

    fn appendLine(self: *LayoutBuilder, glyph_start: u32, glyph_end: u32, byte_start: u32, byte_end: u32) !void {
        std.debug.assert(glyph_start <= glyph_end);
        std.debug.assert(byte_start <= byte_end);
        const origin: f64 = switch (glyph_end > glyph_start) {
            true => self.xs.items[glyph_start],
            false => 0,
        };
        for (self.xs.items[glyph_start..glyph_end]) |*x| x.* -= origin;
        const width: f32 = @floatCast(self.spanWidth(glyph_start, glyph_end));
        const metrics = self.lineMetrics(glyph_start, glyph_end);
        self.uniform = self.uniform and self.uniformLine(glyph_start, glyph_end);
        if (self.uniform) {
            self.y = @as(f32, @floatFromInt(self.lines.items.len)) * metrics.height;
        }
        try self.lines.append(self.system.gpa, .{
            .glyph_start = glyph_start,
            .glyph_end = glyph_end,
            .byte_start = byte_start,
            .byte_end = byte_end,
            .y = self.y,
            .width = width,
            .baseline = metrics.ascender,
            .height = metrics.height,
        });
        self.y += metrics.height;
        self.width = @max(self.width, width);
    }

    fn collectCarets(self: *LayoutBuilder) !void {
        const gpa = self.system.gpa;
        var buffer: [32]i16 = undefined;
        for (self.runs.items) |item| {
            const face = self.system.faceById(item.face);
            const gdef = &face.program.gdef;
            if (gdef.lig_caret_list == null) {
                continue;
            }
            const scale = item.size / face.unitsPerEm();
            for (item.glyph_start..item.glyph_end) |index| {
                if (gdef.props(self.ids.items[index]) & 0x04 == 0) {
                    continue;
                }
                const count = gdef.ligatureCarets(self.ids.items[index], &buffer);
                if (count == 0) {
                    continue;
                }
                try self.carets.append(gpa, .{ .glyph = @intCast(index), .start = @intCast(self.caret_offsets.items.len), .count = @intCast(count) });
                for (buffer[0..count]) |offset| try self.caret_offsets.append(gpa, @as(f32, @floatFromInt(offset)) * scale);
            }
        }
        std.mem.sort(TextLayout.Caret, self.carets.items, {}, struct {
            fn lessThan(_: void, a: TextLayout.Caret, b: TextLayout.Caret) bool {
                return a.glyph < b.glyph;
            }
        }.lessThan);
    }

    fn finish(self: *LayoutBuilder) !*TextLayout {
        const gpa = self.system.gpa;
        const result = try gpa.create(TextLayout);
        errdefer gpa.destroy(result);
        const text_copy = try gpa.dupe(u8, self.text);
        errdefer gpa.free(text_copy);
        const runs = try self.runs.toOwnedSlice(gpa);
        errdefer gpa.free(runs);
        const line_height = self.primary.lineHeight(self.request.size);
        var height = self.y;
        if (self.uniform) {
            height = @as(f32, @floatFromInt(@max(self.lines.items.len, 1))) * line_height;
        }
        result.* = .{
            .text = text_copy,
            .glyphs = .{
                .ids = try self.ids.toOwnedSlice(gpa),
                .x = try self.xs.toOwnedSlice(gpa),
                .advance = try self.advances.toOwnedSlice(gpa),
                .x_offset = try self.x_offsets.toOwnedSlice(gpa),
                .y_offset = try self.y_offsets.toOwnedSlice(gpa),
                .cluster = try self.clusters.toOwnedSlice(gpa),
                .flags = try self.flags.toOwnedSlice(gpa),
            },
            .runs = runs,
            .lines = try self.lines.toOwnedSlice(gpa),
            .carets = try self.carets.toOwnedSlice(gpa),
            .caret_offsets = try self.caret_offsets.toOwnedSlice(gpa),
            .width = self.width,
            .height = height,
            .ascender = self.primary.ascender(self.request.size),
            .line_height = line_height,
            .underline_offset = -@as(f32, @floatFromInt(self.primary.program.metrics.underline_position)) * self.request.size / self.primary.unitsPerEm(),
            .underline_thickness = @as(f32, @floatFromInt(self.primary.program.metrics.underline_thickness)) * self.request.size / self.primary.unitsPerEm(),
        };
        return result;
    }
};

/// Whether the ranged features over the old paragraph `[old_start, old_end]` and the new one
/// `[start, end]` are the same, relative to each paragraph.
fn sameRangesOver(old: []const shape.Plan.Feature, old_start: u32, old_end: u32, new: []const shape.Plan.Feature, start: u32, end: u32) bool {
    var old_index: usize = 0;
    var new_index: usize = 0;
    while (true) {
        while (old_index < old.len and (old[old_index].isGlobal() or !overlaps(old[old_index], old_start, old_end))) old_index += 1;
        while (new_index < new.len and (new[new_index].isGlobal() or !overlaps(new[new_index], start, end))) new_index += 1;
        const old_done = old_index >= old.len;
        const new_done = new_index >= new.len;
        if (old_done or new_done) {
            return old_done and new_done;
        }
        const a = clipped(old[old_index], old_start, old_end);
        const b = clipped(new[new_index], start, end);
        if (!std.meta.eql(a, b)) {
            return false;
        }
        old_index += 1;
        new_index += 1;
    }
}

fn overlaps(feature: shape.Plan.Feature, start: u32, end: u32) bool {
    return feature.start <= end and feature.end > start;
}

fn clipped(feature: shape.Plan.Feature, start: u32, end: u32) shape.Plan.Feature {
    var result = feature;
    result.start = @max(feature.start, start) - start;
    result.end = @min(feature.end, end + 1) - start;
    return result;
}

fn layoutBytes(value: *const TextLayout) usize {
    const glyph_bytes = @sizeOf(u32) * 2 + @sizeOf(f64) + @sizeOf(f32) * 3 + @sizeOf(u8);
    return @sizeOf(TextLayout) + value.text.len + value.glyphs.ids.len * (glyph_bytes + @sizeOf(u32)) +
        value.lines.len * @sizeOf(TextLayout.Line) + value.runs.len * @sizeOf(TextLayout.Run);
}

fn freeLayout(gpa: std.mem.Allocator, value: *TextLayout) void {
    gpa.free(value.text);
    gpa.free(value.glyphs.ids);
    gpa.free(value.glyphs.x);
    gpa.free(value.glyphs.advance);
    gpa.free(value.glyphs.x_offset);
    gpa.free(value.glyphs.y_offset);
    gpa.free(value.glyphs.cluster);
    gpa.free(value.glyphs.flags);
    gpa.free(value.runs);
    gpa.free(value.lines);
    gpa.free(value.carets);
    gpa.free(value.caret_offsets);
    gpa.free(value.slots);
    gpa.destroy(value);
}

test "layout wraps at blanks and caches by request" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const wide = try system.layout(.{ .text = "hello world", .size = 16 });
    try std.testing.expectEqual(@as(usize, 1), wide.lines.len);
    const narrow = try system.layout(.{ .text = "hello world", .size = 16, .wrap_width = wide.width * 0.75 });
    try std.testing.expectEqual(@as(usize, 2), narrow.lines.len);
    try std.testing.expectEqual(@as(u32, 6), narrow.lines[1].byte_start);
    try std.testing.expectEqual(wide, try system.layout(.{ .text = "hello world", .size = 16 }));
    const empty = try system.layout(.{ .text = "", .size = 16 });
    try std.testing.expectEqual(@as(usize, 0), empty.lines.len);
    try std.testing.expectEqual(empty.line_height, empty.height);
    const two = try system.layout(.{ .text = "a\n", .size = 16 });
    try std.testing.expectEqual(@as(usize, 2), two.lines.len);
}

test "caret positions round-trip through points" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const value = try system.layout(.{ .text = "ab\ncd", .size = 20 });
    for ([_]u32{ 0, 1, 2, 3, 4, 5 }) |byte| {
        const point = value.pointForByte(byte);
        try std.testing.expectEqual(byte, value.byteForPoint(.{ .x = point.x + 0.01, .y = point.y + 1 }));
    }
}

test "evicts layouts not used this frame once over budget" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    system.setCacheBudgets(1, 1, 1);
    _ = try system.layout(.{ .text = "old", .size = 12 });
    system.endFrame();
    _ = try system.layout(.{ .text = "new", .size = 12 });
    system.endFrame();
    try std.testing.expectEqual(@as(usize, 1), system.layouts.count());
    try std.testing.expectEqualStrings("new", system.layouts.entries.items[0].value.text);
}

test "carets inside a ligature split it between its graphemes" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const value = try system.layout(.{ .text = "fi", .size = 20 });
    if (value.glyphs.ids.len != 1) {
        return error.SkipZigTest;
    }
    const middle = value.xForByte(1);
    try std.testing.expect(middle > 0);
    try std.testing.expect(middle < value.glyphs.advance[0]);
    try std.testing.expectEqual(@as(u32, 1), value.byteForPoint(.{ .x = @floatCast(middle + 0.01), .y = 1 }));
}

test "ranged features turn a feature off for part of the text" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const liga = std.mem.readInt(u32, "liga", .big);
    const joined = try system.layout(.{ .text = "fi fi", .size = 20 });
    const split = try system.layout(.{ .text = "fi fi", .size = 20, .features = &.{.{ .tag = liga, .value = 0, .start = 0, .end = 2 }} });
    try std.testing.expectEqual(joined.glyphs.ids.len + 1, split.glyphs.ids.len);
}

fn expectSameLayout(expected: *const TextLayout, actual: *const TextLayout) !void {
    try std.testing.expectEqualStrings(expected.text, actual.text);
    try std.testing.expectEqualSlices(u32, expected.glyphs.ids, actual.glyphs.ids);
    try std.testing.expectEqualSlices(f64, expected.glyphs.x, actual.glyphs.x);
    try std.testing.expectEqualSlices(u32, expected.glyphs.cluster, actual.glyphs.cluster);
    try std.testing.expectEqualSlices(u8, expected.glyphs.flags, actual.glyphs.flags);
    try std.testing.expectEqual(expected.lines.len, actual.lines.len);
    for (expected.lines, actual.lines) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(expected.runs.len, actual.runs.len);
    for (expected.runs, actual.runs) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

test "plans stay within budget as feature sets change" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    system.setCacheBudgets(layout_cache_bytes_default, word_cache_bytes_default, 1);
    const liga = std.mem.readInt(u32, "liga", .big);
    const joined = (try system.layout(.{ .text = "fi", .size = 20 })).glyphs.ids.len;
    system.endFrame();
    for (0..1100) |index| {
        const value: u32 = @intCast(index % 2);
        const features = [_]shape.Plan.Feature{ .{ .tag = liga, .value = value }, .{ .tag = std.mem.readInt(u32, "zzzz", .big), .value = @intCast(index) } };
        const built = try system.layout(.{ .text = "fi", .size = 20, .features = &features });
        try std.testing.expectEqual(joined + 1 - value, built.glyphs.ids.len);
        system.endFrame();
        try std.testing.expect(system.plans.count() <= 1);
    }
}

test "keyed edits reuse unchanged paragraphs and match a fresh layout" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const texts = [_][]const u8{
        "first line\nsecond line is longer\n\nfourth fi line\nlast",
        "first line\nsecond line was edited\n\nfourth fi line\nlast",
        "inserted\nfirst line\nsecond line was edited\n\nfourth fi line\nlast",
        "inserted\nfirst line\nsecond line was edited\n\nfourth fi line\nlast!",
        "inserted\nfirst line second line was edited\n\nfourth fi line\nlast!",
        "inserted\nfirst line second line was edited\n\nfourth fi line\nlast!\n",
        "",
        "only one paragraph",
    };
    for ([_]f32{ 0, 60 }) |wrap| {
        for (texts) |content| {
            const keyed = try system.layout(.{ .text = content, .size = 16, .wrap_width = wrap, .key = 7 });
            const fresh = try system.layout(.{ .text = content, .size = 16, .wrap_width = wrap });
            try expectSameLayout(fresh, keyed);
        }
    }
}

test "keyed layouts with moving ranged features match a fresh layout" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const liga = std.mem.readInt(u32, "liga", .big);
    const content = "fi one\nfi two fi\n\nfi four";
    var start: u32 = 0;
    while (start < content.len) : (start += 3) {
        const features = [_]shape.Plan.Feature{.{ .tag = liga, .value = 0, .start = start, .end = start + 2 }};
        const keyed = try system.layout(.{ .text = content, .size = 16, .features = &features, .key = 9 });
        const fresh = try system.layout(.{ .text = content, .size = 16, .features = &features });
        try expectSameLayout(fresh, keyed);
    }
}

test "glyphs map to points and to their cluster's bytes" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    const value = try system.layout(.{ .text = "ab\ncd", .size = 20 });
    for (0..value.glyphs.ids.len) |index| {
        const glyph_index: u32 = @intCast(index);
        const line = value.lines[value.lineForByte(value.glyphs.cluster[index])];
        const x: f32 = @floatCast(value.glyphs.x[index] + value.glyphs.advance[index] / 2);
        try std.testing.expectEqual(@as(?u32, glyph_index), value.glyphAt(.{ .x = x, .y = line.y + 1 }));
        const bytes = value.clusterBytes(glyph_index);
        try std.testing.expectEqual(value.glyphs.cluster[index], bytes[0]);
        try std.testing.expectEqual(bytes[0] + 1, bytes[1]);
    }
    try std.testing.expectEqual(@as(?u32, null), value.glyphAt(.{ .x = value.width + 5, .y = 1 }));
    try std.testing.expectEqual(@as(?u32, null), value.glyphAt(.{ .x = 1, .y = value.height + 5 }));
}
