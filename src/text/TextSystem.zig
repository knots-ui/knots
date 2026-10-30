const std = @import("std");
const builtin = @import("builtin");
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
plans: std.AutoHashMapUnmanaged(PlanKey, *shape.Plan),
feature_sets: std.ArrayList([]shape.Plan.Feature),
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
range_scratch: std.ArrayList(shape.Plan.Feature),
itemize_scratch: itemize.Scratch,
previous: Previous,
frame: u32,
/// Cache counters since init, for tools and diagnostics.
stats: Stats = .{},
/// Pre-shape long texts on worker threads, see `preshape`.
parallel: bool = !builtin.single_threaded,

const TextSystem = @This();

pub const FaceId = TextLayout.FaceId;

pub const faces_max = 256;
pub const families_max = 64;
pub const chain_length_max = itemize.chain_length_max;
pub const layout_cache_bytes_default = 8 * 1024 * 1024;
pub const word_cache_bytes_default = 16 * 1024 * 1024;
pub const segment_glyphs_max = 4096;
pub const tab_size_default = 4;

comptime {
    std.debug.assert(faces_max <= std.math.maxInt(FaceId) + 1);
    std.debug.assert(layout_cache_bytes_default > 0);
    std.debug.assert(families_max == 64 and chain_length_max == 16);
    std.debug.assert(segment_glyphs_max == 4096);
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

const PlanKey = struct {
    face: FaceId,
    script: unicode.Script,
    features: u16,
};

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
    if (sources.len == 0) return error.EmptyFontSet;
    var glyph_store = try GlyphStore.init(gpa);
    errdefer glyph_store.deinit();

    var self: TextSystem = .{
        .gpa = gpa,
        .faces = .empty,
        .families = .empty,
        .plans = .empty,
        .feature_sets = .empty,
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
        .range_scratch = .empty,
        .itemize_scratch = .{},
        .previous = .{},
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
    self.range_scratch.deinit(self.gpa);
    self.itemize_scratch.deinit(self.gpa);
    self.previous.deinit(self.gpa);
    var plans = self.plans.valueIterator();
    while (plans.next()) |plan| {
        plan.*.deinit();
        self.gpa.destroy(plan.*);
    }
    self.plans.deinit(self.gpa);
    for (self.feature_sets.items) |set| self.gpa.free(set);
    self.feature_sets.deinit(self.gpa);
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
        face.program.deinit();
        face.glyphs.deinit(self.gpa);
        self.gpa.destroy(face);
    }
    self.faces.deinit(self.gpa);
}

pub fn addFace(self: *TextSystem, name: []const u8, data: []const u8) !void {
    for (self.faces.items) |face| {
        if (std.mem.eql(u8, face.name, name)) return error.DuplicateFont;
    }
    if (self.faces.items.len >= faces_max) return error.TooManyFonts;
    const face = try self.gpa.create(Face);
    errdefer self.gpa.destroy(face);
    var program = try FontProgram.init(self.gpa, data, 0);
    errdefer program.deinit();
    face.* = .{ .name = name, .program = program };
    try self.faces.append(self.gpa, face);
}

/// A fallback chain of faces, tried in order for each cluster.
pub fn addFamily(self: *TextSystem, name: []const u8, face_names: []const []const u8) !void {
    if (face_names.len == 0 or face_names.len > chain_length_max) return error.InvalidFamily;
    if (self.families.items.len >= families_max) return error.TooManyFamilies;
    for (self.families.items) |family| {
        if (std.mem.eql(u8, family.name, name)) return error.DuplicateFamily;
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
        if (std.mem.eql(u8, family.name, wanted)) return @intCast(index);
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

pub const feature_sets_max = 1024;

/// Interns the shape of a feature list: tags, values and whether each is ranged.
fn featureSet(self: *TextSystem, features: []const shape.Plan.Feature) !u16 {
    if (features.len == 0) return 0;
    var normalized: [shape.Plan.ranged_features_max + 32]shape.Plan.Feature = undefined;
    if (features.len > normalized.len) return error.TooManyFeatures;
    var count: usize = 0;
    for (features) |feature| {
        var entry = feature;
        if (!feature.isGlobal()) {
            entry.start = 0;
            entry.end = 1;
        }
        normalized[count] = entry;
        count += 1;
    }
    for (self.feature_sets.items, 0..) |set, index| {
        if (std.mem.eql(u8, std.mem.sliceAsBytes(set), std.mem.sliceAsBytes(normalized[0..count]))) return @intCast(index + 1);
    }
    if (self.feature_sets.items.len >= feature_sets_max) return error.TooManyFeatureSets;
    try self.feature_sets.append(self.gpa, try self.gpa.dupe(shape.Plan.Feature, normalized[0..count]));
    return @intCast(self.feature_sets.items.len);
}

fn planFor(self: *TextSystem, face_id: FaceId, script: unicode.Script, features: u16) !*const shape.Plan {
    const key: PlanKey = .{ .face = face_id, .script = script, .features = features };
    const entry = try self.plans.getOrPut(self.gpa, key);
    if (entry.found_existing) return entry.value_ptr.*;
    errdefer _ = self.plans.remove(key);
    const plan = try self.gpa.create(shape.Plan);
    errdefer self.gpa.destroy(plan);
    const feature_list: []const shape.Plan.Feature = switch (features) {
        0 => &.{},
        else => self.feature_sets.items[features - 1],
    };
    plan.* = try shape.Plan.init(self.gpa, &self.faceById(face_id).program, .{ .script = script, .features = feature_list });
    entry.value_ptr.* = plan;
    return plan;
}

pub fn faceId(self: *const TextSystem, name: ?[]const u8) !FaceId {
    const wanted = name orelse return 0;
    for (self.faces.items, 0..) |face, index| {
        if (std.mem.eql(u8, face.name, wanted)) return @intCast(index);
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
    if (!std.math.isFinite(size) or size < 0) return error.InvalidPixelSize;
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
    if (target.slot_generation == self.glyph_store.generation and target.slots.len == target.glyphs.ids.len) return target.slots;
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
    if (request.key) |key| return self.keyedLayout(key, chain_id, request);
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
    /// Ranged features the layout was built with.
    ranged: []shape.Plan.Feature,
    /// `featureSet` of the request: plans differ between sets, so paragraphs are reused only within one.
    feature_set: u16,
    frame: u32,

    fn deinit(self: *Keyed, gpa: std.mem.Allocator) void {
        freeLayout(gpa, self.layout);
        gpa.free(self.style);
        gpa.free(self.ranged);
    }

    fn setRanged(self: *Keyed, gpa: std.mem.Allocator, features: []const shape.Plan.Feature) !void {
        const owned = try rangedCopy(gpa, features);
        gpa.free(self.ranged);
        self.ranged = owned;
    }
};

fn rangedCopy(gpa: std.mem.Allocator, features: []const shape.Plan.Feature) ![]shape.Plan.Feature {
    var count: usize = 0;
    for (features) |feature| count += @intFromBool(!feature.isGlobal());
    const owned = try gpa.alloc(shape.Plan.Feature, count);
    var index: usize = 0;
    for (features) |feature| {
        if (feature.isGlobal()) continue;
        owned[index] = feature;
        index += 1;
    }
    return owned;
}

fn sameRanged(old: []const shape.Plan.Feature, features: []const shape.Plan.Feature) bool {
    var index: usize = 0;
    for (features) |feature| {
        if (feature.isGlobal()) continue;
        if (index >= old.len or !std.meta.eql(old[index], feature)) return false;
        index += 1;
    }
    return index == old.len;
}

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
        const same_ranged = sameRanged(keyed.ranged, request.features);
        if (same_ranged and std.mem.eql(u8, old.text, request.text)) {
            self.stats.layout_hits += 1;
            return old;
        }
        self.stats.layout_builds += 1;
        const feature_set = try self.featureSet(request.features);
        const reusable = request.runs.len == 0 and feature_set == keyed.feature_set;
        const reuse: ?Reuse = if (reusable) Reuse.init(old, keyed.ranged, request.text) else null;
        const built = try self.buildReusing(self.chainOf(chain_id), request, reuse);
        errdefer freeLayout(self.gpa, built);
        if (!same_ranged) try keyed.setRanged(self.gpa, request.features);
        keyed.feature_set = feature_set;
        freeLayout(self.gpa, old);
        keyed.layout = built;
        return built;
    }
    if (entry.found_existing) entry.value_ptr.deinit(self.gpa);
    errdefer _ = self.keyed.swapRemove(entry.key_ptr.*);
    const owned_style = try self.gpa.dupe(u8, style);
    errdefer self.gpa.free(owned_style);
    const ranged = try rangedCopy(self.gpa, request.features);
    errdefer self.gpa.free(ranged);
    const feature_set = try self.featureSet(request.features);
    self.stats.layout_builds += 1;
    const built = try self.build(self.chainOf(chain_id), request);
    entry.value_ptr.* = .{ .layout = built, .style = owned_style, .ranged = ranged, .feature_set = feature_set, .frame = self.frame };
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
                if (feature.isGlobal()) try self.key_bytes.appendSlice(gpa, std.mem.asBytes(&feature));
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
    self.frame +%= 1;
    // Best effort: without memory to evict, the store stays over budget for a frame.
    self.glyph_store.endFrame(&self.evicted_glyphs) catch return;
    for (self.evicted_glyphs.items) |owner| {
        const target = self.faceById(@intCast(owner >> 32));
        _ = target.glyphs.remove(@truncate(owner));
    }
}

pub fn setCacheBudgets(self: *TextSystem, layout_bytes: usize, word_bytes: usize) void {
    self.layouts.budget = layout_bytes;
    self.words.budget = word_bytes;
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

/// The last long text shaped on a cache miss, kept to reshape edits incrementally.
const Previous = struct {
    plan: ?*const shape.Plan = null,
    text: std.ArrayList(u8) = .empty,
    glyphs: std.ArrayList(shape.ShapedGlyph) = .empty,

    fn deinit(self: *Previous, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.glyphs.deinit(gpa);
    }

    fn store(self: *Previous, gpa: std.mem.Allocator, plan: *const shape.Plan, text: []const u8, glyphs: []const shape.ShapedGlyph) !void {
        self.plan = null;
        self.text.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        try self.text.appendSlice(gpa, text);
        try self.glyphs.appendSlice(gpa, glyphs);
        self.plan = plan;
    }
};

pub const incremental_bytes_min = 128;

/// Reshapes only the edited middle of `text` against the previous shaping, cutting where glyphs are safe to concatenate.
fn shapeIncremental(self: *TextSystem, face_id: FaceId, plan: *const shape.Plan, text: []const u8) !bool {
    const previous = &self.previous;
    if (previous.plan != plan) return false;
    const old_text = previous.text.items;
    const old_glyphs = previous.glyphs.items;
    if (old_glyphs.len == 0) return false;
    const prefix = std.mem.indexOfDiff(u8, old_text, text) orelse return false;
    var suffix: usize = 0;
    const suffix_max = @min(old_text.len, text.len) - prefix;
    while (suffix < suffix_max and old_text[old_text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;

    const limits = plan.context;
    const left_limit = marginBefore(old_text, prefix, limits.backtrack + 1);
    const suffix_start = marginAfter(old_text, old_text.len - suffix, limits.input + limits.lookahead);
    var left: usize = 0;
    var index: usize = old_glyphs.len;
    while (index > 0) {
        index -= 1;
        const shaped_glyph = old_glyphs[index];
        if (shaped_glyph.cluster > left_limit) continue;
        if (shaped_glyph.flags & shape.shaper.unsafe_to_concat != 0) continue;
        if (index > 0 and old_glyphs[index - 1].cluster == shaped_glyph.cluster) continue;
        left = index;
        break;
    }
    var right = old_glyphs.len;
    for (old_glyphs, 0..) |shaped_glyph, position| {
        if (position <= left or shaped_glyph.cluster < suffix_start) continue;
        if (shaped_glyph.flags & shape.shaper.unsafe_to_concat != 0) continue;
        if (old_glyphs[position - 1].cluster == shaped_glyph.cluster) continue;
        right = position;
        break;
    }
    const left_byte: usize = switch (left == 0) {
        true => 0,
        false => old_glyphs[left].cluster,
    };
    const right_old_byte: usize = switch (right == old_glyphs.len) {
        true => old_text.len,
        false => old_glyphs[right].cluster,
    };
    if (right_old_byte + text.len < old_text.len) return false;
    const right_new_byte = right_old_byte + text.len - old_text.len;
    if (right_new_byte < left_byte) return false;

    self.shaped.clearRetainingCapacity();
    try self.shaped.appendSlice(self.gpa, old_glyphs[0..left]);
    const middle = self.shaped.items.len;
    try self.shapeSegment(face_id, plan, text[left_byte..right_new_byte], &.{});
    for (self.shaped.items[middle..]) |*shaped_glyph| shaped_glyph.cluster += @intCast(left_byte);
    const shift: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old_text.len));
    for (old_glyphs[right..]) |shaped_glyph| {
        var moved = shaped_glyph;
        moved.cluster = @intCast(@as(i64, shaped_glyph.cluster) + shift);
        try self.shaped.append(self.gpa, moved);
    }
    return true;
}

fn isSkippable(codepoint: u32) bool {
    return unicode.generalCategory(codepoint).isMark() or unicode.isDefaultIgnorable(codepoint);
}

/// Byte `count` characters before `byte`, not counting marks and default-ignorables, which lookups can skip.
fn marginBefore(text: []const u8, byte: usize, count: u32) usize {
    var position = byte;
    var remaining = count;
    while (position > 0 and remaining > 0) {
        position -= 1;
        while (position > 0 and text[position] & 0xC0 == 0x80) position -= 1;
        if (!isSkippable(unicode.decodeUtf8(text, position).codepoint)) remaining -= 1;
    }
    return position;
}

fn marginAfter(text: []const u8, byte: usize, count: u32) usize {
    var position = byte;
    var remaining = count;
    while (position < text.len and remaining > 0) {
        const decoded = unicode.decodeUtf8(text, position);
        if (!isSkippable(decoded.codepoint)) remaining -= 1;
        position += decoded.len;
    }
    return position;
}

/// Shapes `text` with `plan`, through the word cache.
fn shapeCached(self: *TextSystem, face_id: FaceId, plan: *const shape.Plan, text: []const u8, ranges: []const shape.Plan.Feature) ![]const shape.ShapedGlyph {
    var key_buffer: [12]u8 = undefined;
    std.mem.writeInt(u64, key_buffer[0..8], @intFromPtr(plan), .little);
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
    const incremental = ranges.len == 0 and text.len >= incremental_bytes_min;
    if (!incremental or !try self.shapeIncremental(face_id, plan, text)) {
        self.shaped.clearRetainingCapacity();
        try self.shapeSegment(face_id, plan, text, ranges);
    }
    if (incremental) try self.previous.store(self.gpa, plan, text, self.shaped.items);
    const owned = try self.gpa.dupe(shape.ShapedGlyph, self.shaped.items);
    return self.words.put(self.gpa, key.items, owned, self.frame);
}

/// Shapes `text` into `self.shaped`, cutting segments longer than the glyph limit at clusters that are safe to concatenate.
fn shapeSegment(self: *TextSystem, face_id: FaceId, plan: *const shape.Plan, text: []const u8, ranges: []const shape.Plan.Feature) !void {
    const program = &self.faceById(face_id).program;
    try shapeChunked(.{ .buffer = &self.buffer, .out = &self.shaped, .ranges = &self.range_scratch, .gpa = self.gpa }, program, plan, text, ranges);
}

/// Where a shaping call works: shared by the system and the pre-shaping workers so both give the same glyphs.
const Shaping = struct {
    buffer: *shape.Buffer,
    out: *std.ArrayList(shape.ShapedGlyph),
    ranges: *std.ArrayList(shape.Plan.Feature),
    gpa: std.mem.Allocator,
};

fn shapeChunked(target: Shaping, program: *const FontProgram, plan: *const shape.Plan, text: []const u8, ranges: []const shape.Plan.Feature) !void {
    const out = target.out;
    var start: usize = 0;
    while (start < text.len) {
        const chunk_end = @min(text.len, start + segment_glyphs_max);
        const base = out.items.len;
        try shape.shaper.shapeRanged(target.buffer, program, plan, text[start..chunk_end], try shiftedRanges(target, ranges, start, chunk_end), target.gpa, out);
        if (chunk_end == text.len) {
            for (out.items[base..]) |*shaped| shaped.cluster += @intCast(start);
            return;
        }
        const cut = safeCut(out.items[base..]) orelse out.items.len - base;
        const cut_byte = cutByte(out.items[base..], cut, chunk_end - start);
        out.shrinkRetainingCapacity(base + cut);
        for (out.items[base..]) |*shaped| shaped.cluster += @intCast(start);
        start += cut_byte;
    }
}

fn shiftedRanges(target: Shaping, ranges: []const shape.Plan.Feature, start: usize, end: usize) ![]const shape.Plan.Feature {
    if (ranges.len == 0) return &.{};
    target.ranges.clearRetainingCapacity();
    for (ranges) |range| {
        if (range.end <= start or range.start >= end) continue;
        var shifted = range;
        shifted.start = @intCast(@max(range.start, start) - start);
        shifted.end = @intCast(@min(range.end, end) - start);
        try target.ranges.append(target.gpa, shifted);
    }
    return target.ranges.items;
}

/// Text at least this long is pre-shaped on worker threads before it is laid out.
pub const parallel_bytes_min = 64 * 1024;
pub const workers_max = 16;

/// Shapes the words of a long text on worker threads and fills the word cache, so the
/// serial layout that follows finds them there. Fonts and plans are only read meanwhile.
fn preshape(self: *TextSystem, chain: Chain, request: Request) !void {
    if (comptime builtin.single_threaded) return;
    if (!self.parallel) return;
    const text = request.text;
    if (text.len < parallel_bytes_min or request.runs.len != 0) return;
    for (request.features) |feature| {
        if (!feature.isGlobal()) return;
    }
    const cpus = std.Thread.getCpuCount() catch return;
    const count = @min(cpus, workers_max, text.len / (parallel_bytes_min / 4));
    if (count < 2) return;
    const feature_set = try self.featureSet(request.features);
    var programs: [chain_length_max]*const FontProgram = undefined;
    for (chain.slice(), 0..) |face_id, index| programs[index] = &self.faceById(face_id).program;
    try self.seedPlans(chain, programs[0..chain.len], text[0..@min(text.len, 16 * 1024)], feature_set);

    var workers: [workers_max]Preshaper = undefined;
    var threads: [workers_max]?std.Thread = @splat(null);
    var start: usize = 0;
    for (0..count) |index| {
        var end = text.len;
        if (index + 1 < count) {
            const target = @max(start, text.len * (index + 1) / count);
            end = if (std.mem.findScalarPos(u8, text, target, '\n')) |newline| newline + 1 else text.len;
        }
        workers[index] = .{ .system = self, .chain = chain, .programs = programs[0..chain.len], .feature_set = feature_set, .text = text, .start = start, .end = end, .arena = .init(std.heap.page_allocator) };
        threads[index] = std.Thread.spawn(.{}, Preshaper.run, .{&workers[index]}) catch null;
        start = end;
    }
    for (threads[0..count], workers[0..count]) |thread, *worker| {
        if (thread) |handle| handle.join() else worker.run();
    }
    defer for (workers[0..count]) |*worker| worker.arena.deinit();
    for (workers[0..count]) |*worker| {
        for (worker.results.items) |word| {
            var key_buffer: [12]u8 = undefined;
            std.mem.writeInt(u64, key_buffer[0..8], @intFromPtr(word.plan), .little);
            std.mem.writeInt(u32, key_buffer[8..12], 0, .little);
            self.word_key.clearRetainingCapacity();
            try self.word_key.appendSlice(self.gpa, &key_buffer);
            try self.word_key.appendSlice(self.gpa, text[word.start..word.end]);
            if (self.words.get(self.word_key.items, self.frame) != null) continue;
            _ = try self.words.put(self.gpa, self.word_key.items, try self.gpa.dupe(shape.ShapedGlyph, word.glyphs), self.frame);
        }
    }
}

/// Creates the plans the start of `text` needs, since workers can't create plans.
fn seedPlans(self: *TextSystem, chain: Chain, programs: []const *const FontProgram, text: []const u8, feature_set: u16) !void {
    self.runs.clearRetainingCapacity();
    try itemize.itemizeWith(self.gpa, &self.itemize_scratch, text, programs, &self.runs);
    for (self.runs.items) |run| _ = try self.planFor(chain.faces[run.face], run.script, feature_set);
}

/// One worker of `preshape`: shapes the distinct words of paragraphs `[start, end)` into its arena.
const Preshaper = struct {
    system: *const TextSystem,
    chain: Chain,
    programs: []const *const FontProgram,
    feature_set: u16,
    text: []const u8,
    start: usize,
    end: usize,
    arena: std.heap.ArenaAllocator,
    results: std.ArrayList(Word) = .empty,

    const Word = struct { plan: *const shape.Plan, start: u32, end: u32, glyphs: []const shape.ShapedGlyph };

    fn run(self: *Preshaper) void {
        // A failed worker leaves its words to the serial layout.
        self.shapeAll() catch {};
    }

    fn shapeAll(self: *Preshaper) !void {
        const gpa = self.arena.allocator();
        var buffer = shape.Buffer.init(gpa);
        var out: std.ArrayList(shape.ShapedGlyph) = .empty;
        var ranges: std.ArrayList(shape.Plan.Feature) = .empty;
        var scratch: itemize.Scratch = .{};
        var items: std.ArrayList(itemize.Run) = .empty;
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        const target: Shaping = .{ .buffer = &buffer, .out = &out, .ranges = &ranges, .gpa = gpa };
        var position = self.start;
        while (position < self.end) {
            // Segments end at newlines and tabs, as in `LayoutBuilder.shapeSpan`.
            var segment_end = position;
            while (segment_end < self.end and self.text[segment_end] != '\n' and self.text[segment_end] != '\t') segment_end += 1;
            if (segment_end > position) {
                items.clearRetainingCapacity();
                try itemize.itemizeWith(gpa, &scratch, self.text[position..segment_end], self.programs, &items);
                for (items.items) |item| {
                    const face_id = self.chain.faces[item.face];
                    const plan = self.system.plans.get(.{ .face = face_id, .script = item.script, .features = self.feature_set }) orelse continue;
                    const program = &self.system.faceById(face_id).program;
                    try self.shapeWords(target, &seen, program, plan, position + item.start, position + item.end);
                }
            }
            position = segment_end + 1;
        }
    }

    /// The words `LayoutBuilder.shapeWords` would look up in the word cache.
    fn shapeWords(self: *Preshaper, target: Shaping, seen: *std.AutoHashMapUnmanaged(u64, void), program: *const FontProgram, plan: *const shape.Plan, start: usize, end: usize) !void {
        if (plan.space_participates) return self.shapeWord(target, seen, program, plan, start, end);
        var word = start;
        while (word < end) {
            var word_end = word + 1;
            const is_space = self.text[word] == ' ';
            while (word_end < end and (self.text[word_end] == ' ') == is_space) word_end += 1;
            try self.shapeWord(target, seen, program, plan, word, word_end);
            word = word_end;
        }
    }

    fn shapeWord(self: *Preshaper, target: Shaping, seen: *std.AutoHashMapUnmanaged(u64, void), program: *const FontProgram, plan: *const shape.Plan, start: usize, end: usize) !void {
        var hasher = std.hash.Wyhash.init(@intFromPtr(plan));
        hasher.update(self.text[start..end]);
        // A hash collision only skips a word, which the serial layout then shapes.
        const entry = try seen.getOrPut(target.gpa, hasher.final());
        if (entry.found_existing) return;
        target.out.clearRetainingCapacity();
        try shapeChunked(target, program, plan, self.text[start..end], &.{});
        try self.results.append(target.gpa, .{ .plan = plan, .start = @intCast(start), .end = @intCast(end), .glyphs = try target.gpa.dupe(shape.ShapedGlyph, target.out.items) });
    }
};

fn safeCut(glyphs: []const shape.ShapedGlyph) ?usize {
    var index = glyphs.len;
    while (index > glyphs.len / 2) {
        index -= 1;
        if (glyphs[index].flags & shape.shaper.unsafe_to_concat != 0) continue;
        if (index > 0 and glyphs[index].cluster == glyphs[index - 1].cluster) continue;
        return index;
    }
    return null;
}

fn cutByte(glyphs: []const shape.ShapedGlyph, cut: usize, chunk_len: usize) usize {
    if (cut >= glyphs.len) return chunk_len;
    return glyphs[cut].cluster;
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
    if (reuse == null) try self.preshape(chain, request);
    return builder.run();
}

/// The bytes an edit left unchanged. A paragraph wholly inside them keeps its layout.
const Reuse = struct {
    old: *const TextLayout,
    /// Ranged features `old` was built with.
    old_ranged: []const shape.Plan.Feature,
    /// New bytes before this offset equal the old text's.
    prefix: usize,
    /// New bytes from this offset on equal the old text's, shifted by `shift`.
    suffix_start: usize,
    shift: i64,

    fn init(old: *const TextLayout, old_ranged: []const shape.Plan.Feature, text: []const u8) Reuse {
        const prefix = std.mem.indexOfDiff(u8, old.text, text) orelse @min(old.text.len, text.len);
        var suffix: usize = 0;
        const suffix_max = @min(old.text.len, text.len) - prefix;
        while (suffix < suffix_max and old.text[old.text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;
        return .{ .old = old, .old_ranged = old_ranged, .prefix = prefix, .suffix_start = text.len - suffix, .shift = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old.text.len)) };
    }

    /// Where the new paragraph `[start, end)` starts in the old text, when its bytes and the
    /// newlines around it are unchanged.
    fn oldStart(self: Reuse, start: usize, end: usize, text_len: usize) ?u32 {
        const last = end == text_len;
        // Before the edit: the paragraph and its terminating newline precede the first change.
        if (end < self.prefix or (last and end <= self.prefix and self.old.text.len == text_len)) return @intCast(start);
        // After the edit: the newline before the paragraph follows the last change.
        if (start == 0 or start - 1 < self.suffix_start) return null;
        return @intCast(@as(i64, @intCast(start)) - self.shift);
    }
};

const Style = struct {
    chain: Chain,
    size: f32,
    features: u16,
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
                const copied = if (self.reuse) |reuse| try self.copyParagraph(reuse, start, end) else false;
                if (!copied) try self.paragraph(@intCast(start), @intCast(end));
                if (end == self.text.len) break;
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
        if (old_end > old.text.len) return false;
        if (old_end < old.text.len and old.text[old_end] != '\n') return false;
        const first = old.lineForByte(old_start);
        if (first >= old.lines.len or old.lines[first].byte_start != old_start) return false;
        var last = first;
        while (last < old.lines.len and old.lines[last].byte_end < old_end) last += 1;
        if (last >= old.lines.len or old.lines[last].byte_end != old_end) return false;
        last += 1;
        const glyph_start = old.lines[first].glyph_start;
        const glyph_end = old.lines[last - 1].glyph_end;
        const shift: i64 = @as(i64, @intCast(start)) - @as(i64, old_start);
        if (!sameRangesOver(reuse.old_ranged, old_start, old_end, self.request.features, @intCast(start), @intCast(end))) return false;
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
            if (run_start >= run_end) continue;
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

    fn isBlank(self: *const LayoutBuilder, glyph_index: u32) bool {
        const byte = self.text[self.clusters.items[glyph_index]];
        return byte == ' ' or byte == '\t';
    }

    fn spanWidth(self: *const LayoutBuilder, first: u32, end: u32) f64 {
        if (first == end) return 0;
        return self.xs.items[end - 1] + self.advances.items[end - 1] - self.xs.items[first];
    }

    fn nextBreak(self: *const LayoutBuilder, line_start: u32) ?Break {
        if (self.wrap_width <= 0) return null;
        const limit: f64 = self.wrap_width;
        const glyph_end = self.glyphCount();
        var last_break: ?u32 = null;
        var index = line_start;
        while (index < glyph_end) : (index += 1) {
            if (self.isBlank(index)) {
                if (index > line_start and !self.isBlank(index - 1)) last_break = index;
                continue;
            }
            if (self.spanWidth(line_start, index + 1) <= limit) continue;
            if (last_break) |break_index| {
                var next = break_index;
                while (next < index and self.isBlank(next)) next += 1;
                return .{ .line_end = break_index, .next = next, .byte_end = self.clusters.items[break_index] };
            }
            if (index > line_start) return .{ .line_end = index, .next = index, .byte_end = self.clusters.items[index] };
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
            if (style_run.end <= byte) continue;
            chosen = style_run;
        }
        if (chosen) |style_run| end = @min(end, style_run.end);
        for (self.request.runs) |style_run| {
            if (style_run.end > byte and style_run.end < end) end = style_run.end;
        }
        const system = self.system;
        var style: Style = .{ .chain = self.chain, .size = self.request.size, .features = 0, .run_features = &.{} };
        self.features.clearRetainingCapacity();
        try self.features.appendSlice(system.gpa, self.request.features);
        if (chosen) |style_run| {
            if (style_run.font != null) style.chain = system.chainOf(try system.chainId(style_run.font));
            if (style_run.size) |size| style.size = size;
            try self.features.appendSlice(system.gpa, style_run.features);
            style.run_features = style_run.features;
        }
        style.features = try system.featureSet(self.features.items);
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
        if (stop > 0) advance = (@floor(pen / stop) + 1) * stop - pen;
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
        if (start == end) return pen_start;
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
            if (feature.isGlobal() or feature.end <= start or feature.start >= end) continue;
            var shifted = feature;
            shifted.start = @max(feature.start, start) - start;
            shifted.end = @min(feature.end, end) - start;
            try self.ranges.append(self.system.gpa, shifted);
        }
        return self.ranges.items;
    }

    fn shapeWords(self: *LayoutBuilder, face_id: FaceId, plan: *const shape.Plan, start: u32, end: u32, pen_start: f64, scale: f32) !f64 {
        if (plan.space_participates) {
            const glyphs = try self.system.shapeCached(face_id, plan, self.text[start..end], try self.rangesFor(start, end));
            return self.appendShaped(glyphs, start, pen_start, scale);
        }
        var pen = pen_start;
        var segment = start;
        while (segment < end) {
            var segment_end = segment + 1;
            const is_space = self.text[segment] == ' ';
            while (segment_end < end and (self.text[segment_end] == ' ') == is_space) segment_end += 1;
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
        if (glyph_end == glyph_start) return;
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
        if (glyph_end == glyph_start) return metrics;
        if (self.uniformLine(glyph_start, glyph_end)) return metrics;
        metrics = .{ .ascender = 0, .height = 0 };
        var descent: f32 = 0;
        for (self.runs.items) |item| {
            if (item.glyph_end <= glyph_start or item.glyph_start >= glyph_end) continue;
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
            if (item.glyph_end <= glyph_start or item.glyph_start >= glyph_end) continue;
            const face = self.system.faceById(item.face);
            if (face.ascender(item.size) != self.primary.ascender(self.request.size)) return false;
            if (face.lineHeight(item.size) != self.primary.lineHeight(self.request.size)) return false;
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
        if (self.uniform) self.y = @as(f32, @floatFromInt(self.lines.items.len)) * metrics.height;
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
            if (gdef.lig_caret_list == null) continue;
            const scale = item.size / face.unitsPerEm();
            for (item.glyph_start..item.glyph_end) |index| {
                if (gdef.props(self.ids.items[index]) & 0x04 == 0) continue;
                const count = gdef.ligatureCarets(self.ids.items[index], &buffer);
                if (count == 0) continue;
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
        if (self.uniform) height = @as(f32, @floatFromInt(@max(self.lines.items.len, 1))) * line_height;
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
        while (old_index < old.len and !overlaps(old[old_index], old_start, old_end)) old_index += 1;
        while (new_index < new.len and (new[new_index].isGlobal() or !overlaps(new[new_index], start, end))) new_index += 1;
        const old_done = old_index >= old.len;
        const new_done = new_index >= new.len;
        if (old_done or new_done) return old_done and new_done;
        const a = clipped(old[old_index], old_start, old_end);
        const b = clipped(new[new_index], start, end);
        if (!std.meta.eql(a, b)) return false;
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
    system.setCacheBudgets(1, 1);
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
    if (value.glyphs.ids.len != 1) return error.SkipZigTest;
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

test "long texts pre-shaped on workers lay out like serial shaping" {
    var system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer system.deinit();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    var line: u32 = 0;
    while (content.items.len < parallel_bytes_min * 2) : (line += 1) {
        try content.print(std.testing.allocator, "line {d}: fi ffi caf\u{e9} \tvalue != other -> {d}\n", .{ line, line * 7 });
    }
    const parallel = try system.layout(.{ .text = content.items, .size = 14 });
    var serial_system = try TextSystem.init(std.testing.allocator, &.{.{ .name = "default", .data = @embedFile("test_font") }});
    defer serial_system.deinit();
    serial_system.parallel = false;
    const serial = try serial_system.layout(.{ .text = content.items, .size = 14 });
    try expectSameLayout(serial, parallel);
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
