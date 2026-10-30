const std = @import("std");
const tables = @import("tables.zig");

pub const grapheme = @import("grapheme.zig");
pub const Script = tables.Script;
pub const unicode_version = tables.unicode_version;

pub const GeneralCategory = enum(u5) {
    control,
    format,
    unassigned,
    private_use,
    surrogate,
    lowercase_letter,
    modifier_letter,
    other_letter,
    titlecase_letter,
    uppercase_letter,
    spacing_mark,
    enclosing_mark,
    non_spacing_mark,
    decimal_number,
    letter_number,
    other_number,
    connect_punctuation,
    dash_punctuation,
    close_punctuation,
    final_punctuation,
    initial_punctuation,
    other_punctuation,
    open_punctuation,
    currency_symbol,
    modifier_symbol,
    math_symbol,
    other_symbol,
    line_separator,
    paragraph_separator,
    space_separator,

    pub fn isMark(category: GeneralCategory) bool {
        return switch (category) {
            .spacing_mark, .enclosing_mark, .non_spacing_mark => true,
            else => false,
        };
    }
};

pub const GraphemeBreak = enum(u4) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
};

pub const ConjunctBreak = enum(u2) { none, linker, consonant, extend };

pub const Props = packed struct(u32) {
    general_category: GeneralCategory,
    combining_class: u8,
    script: Script,
    grapheme_break: GraphemeBreak,
    extended_pictographic: bool,
    default_ignorable: bool,
    conjunct_break: ConjunctBreak,
    padding: u3,
};

pub const replacement_character = 0xFFFD;
pub const codepoint_max = 0x10FFFF;

pub const Decoded = struct {
    codepoint: u32,
    len: u3,
};

/// Decodes one codepoint, mapping every invalid byte to U+FFFD.
pub fn decodeUtf8(text: []const u8, index: usize) Decoded {
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch return .{ .codepoint = replacement_character, .len = 1 };
    if (index + len > text.len) return .{ .codepoint = replacement_character, .len = 1 };
    const codepoint = std.unicode.utf8Decode(text[index..][0..len]) catch return .{ .codepoint = replacement_character, .len = 1 };
    return .{ .codepoint = codepoint, .len = len };
}

pub fn props(codepoint: u32) Props {
    if (codepoint > codepoint_max) return props(replacement_character);
    const block = tables.stage1[codepoint >> tables.block_shift];
    const block_len = 1 << tables.block_shift;
    const index = tables.stage2[@as(usize, block) * block_len + (codepoint & (block_len - 1))];
    return @bitCast(tables.values[index]);
}

pub fn generalCategory(codepoint: u32) GeneralCategory {
    return props(codepoint).general_category;
}

pub fn combiningClass(codepoint: u32) u8 {
    return props(codepoint).combining_class;
}

pub fn script(codepoint: u32) Script {
    return props(codepoint).script;
}

const modified_combining_classes = [256]u8{
    0,   1,   2,   3,   4,   5,   6,   7,   8,   9,   22,  15,  16,  17,  23,  18,
    19,  20,  21,  14,  24,  12,  25,  13,  10,  11,  26,  28,  29,  30,  31,  32,
    33,  27,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,
    48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,
    64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,
    80,  81,  82,  83,  4,   85,  86,  87,  88,  89,  90,  5,   92,  93,  94,  95,
    96,  97,  98,  99,  100, 101, 102, 3,   104, 105, 106, 107, 108, 109, 110, 111,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
    128, 129, 132, 131, 131, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
    192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207,
    208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
    224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255,
};

/// HarfBuzz's reordering class, see `modified_combining_class` in hb-unicode.hh.
pub fn modifiedCombiningClass(codepoint: u32) u8 {
    return switch (codepoint) {
        0x1A60, 0x0FC6 => 254,
        0x0F39 => 127,
        else => modified_combining_classes[combiningClass(codepoint)],
    };
}

/// HarfBuzz's narrower default-ignorable set, see `is_default_ignorable` in hb-unicode.hh.
pub fn isDefaultIgnorable(codepoint: u32) bool {
    return switch (codepoint) {
        0x00AD, 0x034F, 0x061C => true,
        0x17B4...0x17B5, 0x180B...0x180F => true,
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F => true,
        0xFE00...0xFE0F, 0xFEFF, 0xFFF0...0xFFF8 => true,
        0x1D173...0x1D17A, 0xE0000...0xE0FFF => true,
        else => false,
    };
}

pub fn isVariationSelector(codepoint: u32) bool {
    return switch (codepoint) {
        0xFE00...0xFE0F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

pub fn isRegionalIndicator(codepoint: u32) bool {
    return codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF;
}

pub fn mirroring(codepoint: u32) u32 {
    const index = std.sort.binarySearch([2]u32, &tables.mirrors, codepoint, compareMirror) orelse return codepoint;
    return tables.mirrors[index][1];
}

fn compareMirror(codepoint: u32, entry: [2]u32) std.math.Order {
    return std.math.order(codepoint, entry[0]);
}

const hangul_s_base = 0xAC00;
const hangul_l_base = 0x1100;
const hangul_v_base = 0x1161;
const hangul_t_base = 0x11A7;
const hangul_l_count = 19;
const hangul_v_count = 21;
const hangul_t_count = 28;
const hangul_n_count = hangul_v_count * hangul_t_count;
const hangul_s_count = hangul_l_count * hangul_n_count;

pub const Pair = struct { first: u32, second: u32 };

/// One level of canonical decomposition. A singleton decomposes to `second == 0`.
pub fn decompose(codepoint: u32) ?Pair {
    if (decomposeHangul(codepoint)) |pair| return pair;
    const index = std.sort.binarySearch(tables.Decomposition, &tables.decompositions, codepoint, compareDecomposition) orelse return null;
    const entry = tables.decompositions[index];
    return .{ .first = entry.first, .second = entry.second };
}

fn compareDecomposition(codepoint: u32, entry: tables.Decomposition) std.math.Order {
    return std.math.order(codepoint, entry.codepoint);
}

fn decomposeHangul(codepoint: u32) ?Pair {
    if (codepoint < hangul_s_base or codepoint >= hangul_s_base + hangul_s_count) return null;
    const index = codepoint - hangul_s_base;
    const t_index = index % hangul_t_count;
    if (t_index != 0) return .{ .first = codepoint - t_index, .second = hangul_t_base + t_index };
    return .{
        .first = hangul_l_base + index / hangul_n_count,
        .second = hangul_v_base + (index % hangul_n_count) / hangul_t_count,
    };
}

pub fn compose(first: u32, second: u32) ?u32 {
    if (composeHangul(first, second)) |composed| return composed;
    const index = std.sort.binarySearch(tables.Composition, &tables.compositions, Pair{ .first = first, .second = second }, compareComposition) orelse return null;
    return tables.compositions[index].composed;
}

fn compareComposition(pair: Pair, entry: tables.Composition) std.math.Order {
    if (pair.first != entry.first) return std.math.order(pair.first, entry.first);
    return std.math.order(pair.second, entry.second);
}

fn composeHangul(first: u32, second: u32) ?u32 {
    if (first >= hangul_l_base and first < hangul_l_base + hangul_l_count and
        second >= hangul_v_base and second < hangul_v_base + hangul_v_count)
    {
        const l_index = first - hangul_l_base;
        const v_index = second - hangul_v_base;
        return hangul_s_base + (l_index * hangul_v_count + v_index) * hangul_t_count;
    }
    if (first >= hangul_s_base and first < hangul_s_base + hangul_s_count and
        (first - hangul_s_base) % hangul_t_count == 0 and
        second > hangul_t_base and second < hangul_t_base + hangul_t_count)
    {
        return first + (second - hangul_t_base);
    }
    return null;
}

test {
    _ = grapheme;
}

test "properties of common characters" {
    try std.testing.expectEqual(GeneralCategory.uppercase_letter, generalCategory('A'));
    try std.testing.expectEqual(GeneralCategory.non_spacing_mark, generalCategory(0x0301));
    try std.testing.expectEqual(@as(u8, 230), combiningClass(0x0301));
    try std.testing.expectEqual(Script.latn, script('a'));
    try std.testing.expectEqual(Script.zyyy, script(' '));
    try std.testing.expectEqual(Script.zinh, script(0x0301));
    try std.testing.expectEqual(GeneralCategory.unassigned, generalCategory(0x10FFFF));
    try std.testing.expect(props(0x1F600).extended_pictographic);
    try std.testing.expectEqual(GraphemeBreak.zwj, props(0x200D).grapheme_break);
    try std.testing.expectEqual(@as(u32, ')'), mirroring('('));
    try std.testing.expectEqual(@as(u32, 'x'), mirroring('x'));
}

test "decomposition and composition" {
    try std.testing.expectEqual(Pair{ .first = 'e', .second = 0x0301 }, decompose(0x00E9).?);
    try std.testing.expectEqual(@as(?u32, 0x00E9), compose('e', 0x0301));
    try std.testing.expectEqual(@as(?u32, null), compose(0x0915, 0x093C));
    try std.testing.expectEqual(Pair{ .first = 0xAC00, .second = 0x11A8 }, decompose(0xAC01).?);
    try std.testing.expectEqual(@as(?u32, 0xAC01), compose(0xAC00, 0x11A8));
    try std.testing.expectEqual(@as(?u32, 0xAC00), compose(0x1100, 0x1161));
}
