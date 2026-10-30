//! A shape plan: the feature masks and lookup lists for one face, script,
//! language and feature set, following hb-ot-map.cc and hb-ot-shape.cc.

const std = @import("std");
const FontProgram = @import("../font/FontProgram.zig");
const Layout = @import("../font/Layout.zig");
const Partition = @import("../font/Partition.zig");
const unicode = @import("../unicode/root.zig");
const participation = @import("../font/participation.zig");
const Follow = @import("follow.zig");

arena_state: std.heap.ArenaAllocator,
global_mask: u32,
features: []const FeatureMap,
lookups: [2][]const LookupMap,
fallback_glyph_classes: bool,
apply_gpos: bool,
apply_kern: bool,
zero_marks: bool,
adjust_mark_positioning_when_zeroing: bool,
fallback_mark_positioning: bool,
kern_mask: u32,
frac_mask: u32,
numr_mask: u32,
dnom_mask: u32,
has_frac: bool,
/// Words per class in `class_lookups`, one bit per lookup ordinal of the table.
lookup_words: [2]u32,
/// For each class, the lookup ordinals it can start: covered by a subtable and not skipped
/// by the lookup flags.
class_lookups: [2][]const u64,
/// Lookup ordinals whose start set covers a large share of classes, one bit each. The
/// scheduler scans for them instead of indexing their positions.
dense: [2][]const u64,
/// What the glyph after a candidate decides, per lookup index and start class. Owned by the face.
follow: [2]*const Follow.Rows,
space_participates: bool,
key_ranges: []const Feature,

const Plan = @This();

pub const global_bit_shift = 31;
pub const global_bit_mask: u32 = 1 << global_bit_shift;
pub const max_bits = 8;
pub const max_value: u32 = (1 << max_bits) - 1;
pub const first_feature_bit = 4;
pub const ranged_features_max = 31;

comptime {
    std.debug.assert(first_feature_bit == @popCount(@as(u32, 0x7)) + 1);
    std.debug.assert(max_value == 255);
}

pub const Feature = struct {
    tag: u32,
    value: u32 = 1,
    start: u32 = 0,
    end: u32 = std.math.maxInt(u32),

    pub fn isGlobal(feature: Feature) bool {
        return feature.start == 0 and feature.end == std.math.maxInt(u32);
    }
};

pub const Key = struct {
    script: unicode.Script = .latn,
    language: ?u32 = null,
    features: []const Feature = &.{},
};

pub const FeatureMap = struct {
    tag: u32,
    index: [2]u16,
    stage: [2]u32,
    shift: u5,
    mask: u32,
    one_mask: u32,
    auto_zwnj: bool,
    auto_zwj: bool,
    random: bool,
};

pub const LookupMap = struct {
    index: u16,
    mask: u32,
    auto_zwnj: bool,
    auto_zwj: bool,
    random: bool,
};

pub fn tag(name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

const Flags = packed struct {
    global: bool = false,
    has_fallback: bool = false,
    manual_zwnj: bool = false,
    manual_zwj: bool = false,
    random: bool = false,
};

const FeatureInfo = struct {
    tag: u32,
    seq: u32,
    max_value: u32,
    flags: Flags,
    default_value: u32,
    stage: [2]u32,
};

pub fn deinit(self: *Plan) void {
    self.arena_state.deinit();
}

pub fn mask(self: *const Plan, feature_tag: u32) struct { mask: u32, shift: u5 } {
    for (self.features) |feature| {
        if (feature.tag == feature_tag) {
            return .{ .mask = feature.mask, .shift = feature.shift };
        }
    }
    return .{ .mask = 0, .shift = 0 };
}

pub fn oneMask(self: *const Plan, feature_tag: u32) u32 {
    for (self.features) |feature| {
        if (feature.tag == feature_tag) {
            return feature.one_mask;
        }
    }
    return 0;
}

fn featureIndex(self: *const Plan, table: usize, feature_tag: u32) u16 {
    for (self.features) |feature| {
        if (feature.tag == feature_tag) {
            return feature.index[table];
        }
    }
    return Layout.no_index;
}

pub fn scriptTags(script: unicode.Script, out: *[3]u32) []const u32 {
    var count: usize = 0;
    const new_tag: ?u32 = switch (script) {
        .beng => tag("bng2"),
        .deva => tag("dev2"),
        .gujr => tag("gjr2"),
        .guru => tag("gur2"),
        .knda => tag("knd2"),
        .mlym => tag("mlm2"),
        .orya => tag("ory2"),
        .taml => tag("tml2"),
        .telu => tag("tel2"),
        .mymr => tag("mym2"),
        else => null,
    };
    if (new_tag) |value| {
        if (value != tag("mym2")) {
            out[count] = (value & 0xFFFFFF00) | '3';
            count += 1;
        }
        out[count] = value;
        count += 1;
    }
    out[count] = oldScriptTag(script);
    count += 1;
    return out[0..count];
}

fn oldScriptTag(script: unicode.Script) u32 {
    return switch (script) {
        .hira, .kana, .hrkt => tag("kana"),
        .laoo => tag("lao "),
        .yiii => tag("yi  "),
        .nkoo => tag("nko "),
        .vaii => tag("vai "),
        else => std.mem.readInt(u32, @tagName(script)[0..4], .big),
    };
}

const Builder = struct {
    arena: std.mem.Allocator,
    program: *const FontProgram,
    infos: std.ArrayList(FeatureInfo) = .empty,
    current_stage: [2]u32 = .{ 0, 0 },
    script_index: [2]u16 = .{ Layout.no_index, Layout.no_index },
    language_index: [2]u16 = .{ Layout.no_index, Layout.no_index },
    is_simple: bool = true,

    fn table(self: *const Builder, index: usize) *const Layout {
        return switch (index) {
            0 => &self.program.gsub,
            else => &self.program.gpos,
        };
    }

    fn add(self: *Builder, feature_tag: u32, flags: Flags, value: u32) !void {
        const default_value: u32 = switch (flags.global) {
            true => value,
            false => 0,
        };
        try self.infos.append(self.arena, .{
            .tag = feature_tag,
            .seq = @intCast(self.infos.items.len + 1),
            .max_value = value,
            .flags = flags,
            .default_value = default_value,
            .stage = self.current_stage,
        });
    }

    fn enable(self: *Builder, feature_tag: u32, flags: Flags, value: u32) !void {
        var global = flags;
        global.global = true;
        try self.add(feature_tag, global, value);
    }

    fn pause(self: *Builder, table_index: usize) void {
        self.current_stage[table_index] += 1;
    }

    fn selectScripts(self: *Builder, key: Key) void {
        var buffer: [3]u32 = undefined;
        const script_tags = scriptTags(key.script, &buffer);
        for (0..2) |table_index| {
            const layout = self.table(table_index);
            self.selectScript(table_index, layout, script_tags);
            self.language_index[table_index] = selectLanguage(layout, self.script_index[table_index], key.language);
        }
    }

    fn selectScript(self: *Builder, table_index: usize, layout: *const Layout, script_tags: []const u32) void {
        for (script_tags) |script_tag| {
            if (layout.findScript(script_tag)) |index| {
                self.script_index[table_index] = index;
                return;
            }
        }
        for ([_]u32{ tag("DFLT"), tag("dflt"), tag("latn") }) |fallback| {
            if (layout.findScript(fallback)) |index| {
                self.script_index[table_index] = index;
                return;
            }
        }
    }

    fn selectLanguage(layout: *const Layout, script: u16, language: ?u32) u16 {
        if (script == Layout.no_index) {
            return Layout.no_index;
        }
        if (language) |wanted| {
            if (layout.findLanguage(script, wanted)) |index| {
                return index;
            }
        }
        if (layout.findLanguage(script, tag("dflt"))) |index| {
            return index;
        }
        return Layout.no_index;
    }

    fn collectFeatures(self: *Builder, key: Key) !void {
        try self.enable(tag("rvrn"), .{}, 1);
        self.pause(0);
        try self.enable(tag("ltra"), .{}, 1);
        try self.enable(tag("ltrm"), .{}, 1);
        try self.add(tag("frac"), .{}, 1);
        try self.add(tag("numr"), .{}, 1);
        try self.add(tag("dnom"), .{}, 1);
        try self.enable(tag("rand"), .{ .random = true }, max_value);
        try self.enable(tag("Harf"), .{}, 1);
        try self.enable(tag("HARF"), .{}, 1);
        try self.enable(tag("Buzz"), .{}, 1);
        try self.enable(tag("BUZZ"), .{}, 1);
        inline for (.{ "abvm", "blwm", "ccmp", "locl" }) |name| try self.add(tag(name), .{ .global = true }, 1);
        try self.add(tag("mark"), .{ .global = true, .manual_zwnj = true, .manual_zwj = true }, 1);
        try self.add(tag("mkmk"), .{ .global = true, .manual_zwnj = true, .manual_zwj = true }, 1);
        try self.add(tag("rlig"), .{ .global = true }, 1);
        inline for (.{ "calt", "clig", "curs", "dist" }) |name| try self.add(tag(name), .{ .global = true }, 1);
        try self.add(tag("kern"), .{ .global = true, .has_fallback = true }, 1);
        try self.add(tag("liga"), .{ .global = true }, 1);
        try self.add(tag("rclt"), .{ .global = true }, 1);
        if (key.features.len > 0) {
            self.is_simple = false;
        }
        for (key.features) |feature| try self.add(feature.tag, .{ .global = feature.isGlobal() }, feature.value);
    }

    fn mergeFeatures(self: *Builder) void {
        const infos = self.infos.items;
        if (infos.len == 0) {
            return;
        }
        if (!self.is_simple) {
            std.mem.sort(FeatureInfo, infos, {}, infoLessThan);
        }
        var j: usize = 0;
        for (infos[1..]) |info| {
            if (info.tag != infos[j].tag) {
                j += 1;
                infos[j] = info;
                continue;
            }
            const target = &infos[j];
            if (info.flags.global) {
                target.flags.global = true;
                target.max_value = info.max_value;
                target.default_value = info.default_value;
            } else {
                target.flags.global = false;
                target.max_value = @max(target.max_value, info.max_value);
            }
            target.flags.has_fallback = target.flags.has_fallback or info.flags.has_fallback;
            target.stage[0] = @min(target.stage[0], info.stage[0]);
            target.stage[1] = @min(target.stage[1], info.stage[1]);
        }
        self.infos.shrinkRetainingCapacity(j + 1);
    }

    fn infoLessThan(_: void, a: FeatureInfo, b: FeatureInfo) bool {
        if (a.tag != b.tag) {
            return a.tag < b.tag;
        }
        return a.seq < b.seq;
    }

    fn langSysFeature(self: *const Builder, table_index: usize, feature_tag: u32) ?u16 {
        const layout = self.table(table_index);
        const lang_sys = layout.langSys(self.script_index[table_index], self.language_index[table_index]);
        const count = Layout.langSysFeatureCount(lang_sys);
        for (0..count) |index| {
            const feature = Layout.langSysFeature(lang_sys, @intCast(index));
            if (layout.featureTag(feature) == feature_tag) {
                return feature;
            }
        }
        return null;
    }
};

pub fn init(gpa: std.mem.Allocator, program: *const FontProgram, follow: *Follow.Store, key: Key) !Plan {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var builder: Builder = .{ .arena = arena, .program = program };
    builder.selectScripts(key);
    try builder.collectFeatures(key);

    var global_mask = global_bit_mask;
    var required_index: [2]u16 = undefined;
    var required_tag: [2]u32 = undefined;
    var required_stage: [2]u32 = .{ 0, 0 };
    for (0..2) |table_index| {
        const layout = builder.table(table_index);
        const lang_sys = layout.langSys(builder.script_index[table_index], builder.language_index[table_index]);
        required_index[table_index] = Layout.requiredFeature(lang_sys);
        required_tag[table_index] = layout.featureTag(required_index[table_index]);
    }

    builder.mergeFeatures();
    var features: std.ArrayList(FeatureMap) = .empty;
    var next_bit: u32 = first_feature_bit;
    for (builder.infos.items) |info| {
        const uses_global_bit = info.flags.global and info.max_value == 1;
        const bits_needed: u32 = switch (uses_global_bit) {
            true => 0,
            false => @min(max_bits, bitStorage(info.max_value)),
        };
        if (info.max_value == 0 or next_bit + bits_needed >= global_bit_shift) {
            continue;
        }
        var found = false;
        var index: [2]u16 = .{ Layout.no_index, Layout.no_index };
        for (0..2) |table_index| {
            if (required_tag[table_index] == info.tag) {
                required_stage[table_index] = info.stage[table_index];
            }
            if (builder.langSysFeature(table_index, info.tag)) |feature| {
                index[table_index] = feature;
                found = true;
            }
        }
        if (!found and !info.flags.has_fallback) {
            continue;
        }
        var map: FeatureMap = .{
            .tag = info.tag,
            .index = index,
            .stage = info.stage,
            .shift = global_bit_shift,
            .mask = global_bit_mask,
            .one_mask = 0,
            .auto_zwnj = !info.flags.manual_zwnj,
            .auto_zwj = !info.flags.manual_zwj,
            .random = info.flags.random,
        };
        if (!uses_global_bit) {
            map.shift = @intCast(next_bit);
            map.mask = (@as(u32, 1) << @intCast(next_bit + bits_needed)) - (@as(u32, 1) << @intCast(next_bit));
            next_bit += bits_needed;
            global_mask |= (info.default_value << map.shift) & map.mask;
        }
        map.one_mask = (@as(u32, 1) << map.shift) & map.mask;
        try features.append(arena, map);
    }
    builder.pause(0);
    builder.pause(1);

    var start_context: StartContext = try .init(arena, program);

    var plan: Plan = .{
        .arena_state = undefined,
        .global_mask = global_mask,
        .features = features.items,
        .lookups = undefined,
        .fallback_glyph_classes = !program.gdef.has_glyph_classes,
        .apply_gpos = program.gpos.present,
        .apply_kern = false,
        .zero_marks = true,
        .adjust_mark_positioning_when_zeroing = false,
        .fallback_mark_positioning = false,
        .kern_mask = 0,
        .frac_mask = 0,
        .numr_mask = 0,
        .dnom_mask = 0,
        .has_frac = false,
        .lookup_words = .{ 0, 0 },
        .class_lookups = .{ &.{}, &.{} },
        .dense = .{ &.{}, &.{} },
        .follow = .{ &follow.tables[0], &follow.tables[1] },
        .space_participates = false,
        .key_ranges = &.{},
    };
    const class_count = program.partition.class_count;
    for (0..2) |table_index| {
        var list: std.ArrayList(LookupMap) = .empty;
        var last: usize = 0;
        const layout = builder.table(table_index);
        const variations = layout.defaultVariations();
        for (0..builder.current_stage[table_index]) |stage| {
            if (required_index[table_index] != Layout.no_index and required_stage[table_index] == stage) {
                try addLookups(arena, &list, layout, required_index[table_index], variations, .{ .mask = global_bit_mask, .auto_zwnj = true, .auto_zwj = true, .random = false });
            }
            for (features.items) |feature| {
                if (feature.stage[table_index] != stage or feature.index[table_index] == Layout.no_index) {
                    continue;
                }
                try addLookups(arena, &list, layout, feature.index[table_index], variations, .{
                    .mask = feature.mask,
                    .auto_zwnj = feature.auto_zwnj,
                    .auto_zwj = feature.auto_zwj,
                    .random = feature.random,
                });
            }
            mergeLookups(&list, last);
            last = list.items.len;
        }
        const words: u32 = @intCast((list.items.len + 63) / 64);
        const bits = try arena.alloc(u64, @as(usize, class_count) * words);
        @memset(bits, 0);
        const dense = try arena.alloc(u64, words);
        @memset(dense, 0);
        const start_set = try arena.alloc(u64, program.partition.set_words);
        for (list.items, 0..) |lookup_map, ordinal| {
            const bit = @as(u64, 1) << @intCast(ordinal % 64);
            start_context.startSet(layout.lookups[lookup_map.index], start_set);
            try follow.tables[table_index].ensure(gpa, program, lookup_map.index, start_set);
            var covered: u32 = 0;
            for (start_set, 0..) |start_word, word_index| {
                var remaining = start_word;
                while (remaining != 0) : (remaining &= remaining - 1) {
                    const class = word_index * 64 + @ctz(remaining);
                    bits[class * words + ordinal / 64] |= bit;
                    covered += 1;
                }
            }
            if (covered * dense_share >= class_count) {
                dense[ordinal / 64] |= bit;
            }
        }
        plan.lookups[table_index] = list.items;
        plan.lookup_words[table_index] = words;
        plan.class_lookups[table_index] = bits;
        plan.dense[table_index] = dense;
    }
    var ranged: std.ArrayList(Feature) = .empty;
    for (key.features) |feature| {
        if (!feature.isGlobal()) {
            try ranged.append(arena, feature);
        }
    }
    plan.key_ranges = ranged.items;
    plan.kern_mask = plan.mask(tag("kern")).mask;
    plan.frac_mask = plan.oneMask(tag("frac"));
    plan.numr_mask = plan.oneMask(tag("numr"));
    plan.dnom_mask = plan.oneMask(tag("dnom"));
    plan.has_frac = plan.frac_mask != 0 or (plan.numr_mask != 0 and plan.dnom_mask != 0);
    const has_gpos_kern = plan.featureIndex(1, tag("kern")) != Layout.no_index;
    if (!has_gpos_kern or !plan.apply_gpos) {
        plan.apply_kern = program.kern.present;
    }
    plan.zero_marks = !plan.apply_kern or !program.kern.has_state_machine;
    plan.adjust_mark_positioning_when_zeroing = !plan.apply_gpos and (!plan.apply_kern or !program.kern.has_cross_stream);
    plan.fallback_mark_positioning = plan.adjust_mark_positioning_when_zeroing;
    plan.space_participates = participation.spaceParticipates(program, plan.lookups, plan.apply_kern);
    plan.arena_state = arena_state;
    return plan;
}

/// A lookup is dense when its start set holds at least 1/`dense_share` of the classes.
const dense_share = 4;

pub fn isDense(self: *const Plan, table_index: usize, ordinal: u32) bool {
    return self.dense[table_index][ordinal / 64] >> @intCast(ordinal % 64) & 1 != 0;
}

/// Whether glyphs of `class` can start lookup `ordinal` of the table.
pub fn canStart(self: *const Plan, table_index: usize, ordinal: u32, class: u16) bool {
    const words = self.lookup_words[table_index];
    const word = self.class_lookups[table_index][@as(usize, class) * words + ordinal / 64];
    return word >> @intCast(ordinal % 64) & 1 != 0;
}

fn bitStorage(value: u32) u32 {
    return 32 - @clz(value);
}

const LookupFlags = struct {
    mask: u32,
    auto_zwnj: bool,
    auto_zwj: bool,
    random: bool,
};

fn addLookups(arena: std.mem.Allocator, list: *std.ArrayList(LookupMap), layout: *const Layout, feature: u16, variations: ?u32, flags: LookupFlags) !void {
    const indices = layout.featureLookups(feature, variations);
    var offset: usize = 0;
    while (offset + 2 <= indices.len) : (offset += 2) {
        const index = std.mem.readInt(u16, indices[offset..][0..2], .big);
        if (index >= layout.lookups.len) {
            continue;
        }
        try list.append(arena, .{
            .index = index,
            .mask = flags.mask,
            .auto_zwnj = flags.auto_zwnj,
            .auto_zwj = flags.auto_zwj,
            .random = flags.random,
        });
    }
}

fn mergeLookups(list: *std.ArrayList(LookupMap), start: usize) void {
    const items = list.items;
    if (start + 1 >= items.len) {
        return;
    }
    std.sort.pdq(LookupMap, items[start..], {}, struct {
        fn lessThan(_: void, a: LookupMap, b: LookupMap) bool {
            return a.index < b.index;
        }
    }.lessThan);
    var j = start;
    for (items[start + 1 ..]) |lookup| {
        if (lookup.index != items[j].index) {
            j += 1;
            items[j] = lookup;
            continue;
        }
        items[j].mask |= lookup.mask;
        items[j].auto_zwnj = items[j].auto_zwnj and lookup.auto_zwnj;
        items[j].auto_zwj = items[j].auto_zwj and lookup.auto_zwj;
    }
    list.shrinkRetainingCapacity(j + 1);
}

/// Whether a class's glyphs are covered by some subtable of a lookup and not skipped by its flags.
const StartContext = struct {
    program: *const FontProgram,
    class_props: []u16,

    fn init(arena: std.mem.Allocator, program: *const FontProgram) !StartContext {
        const partition = &program.partition;
        const class_props = try arena.alloc(u16, partition.class_count);
        @memset(class_props, 0);
        for (partition.class_of, 0..) |class, glyph| {
            class_props[class] = program.gdef.props(@intCast(glyph));
        }
        return .{ .program = program, .class_props = class_props };
    }

    /// Fills `bits` with the classes that can start `lookup`.
    fn startSet(self: *const StartContext, lookup: Layout.Lookup, bits: []u64) void {
        const partition = &self.program.partition;
        @memset(bits, 0);
        for (lookup.subtables) |subtable| {
            for (bits, partition.setBits(subtable.coverage_id)) |*word, covered| {
                word.* |= covered;
            }
        }
        if (!self.program.gdef.has_glyph_classes) {
            return;
        }
        const lookup_props = lookup.props();
        for (bits, 0..) |*word, word_index| {
            var remaining = word.*;
            while (remaining != 0) : (remaining &= remaining - 1) {
                const class: u16 = @intCast(word_index * 64 + @ctz(remaining));
                if (self.program.skipsClass(lookup_props, self.class_props[class], class)) {
                    word.* &= ~(@as(u64, 1) << @intCast(class % 64));
                }
            }
        }
    }
};
