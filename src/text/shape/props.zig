//! Per-glyph property bits, mirroring hb-ot-layout.hh.

const unicode = @import("../unicode/root.zig");
const Gdef = @import("../font/Gdef.zig");

pub const general_category_mask: u16 = 0x001F;
pub const ignorable: u16 = 0x0020;
pub const hidden: u16 = 0x0040;
pub const continuation: u16 = 0x0080;
pub const cf_zwj: u16 = 0x0100;
pub const cf_zwnj: u16 = 0x0200;
pub const cf_vs: u16 = 0x0400;

pub const glyph_base = Gdef.props_base_glyph;
pub const glyph_ligature = Gdef.props_ligature;
pub const glyph_mark = Gdef.props_mark;
pub const glyph_class_mask = Gdef.props_class_mask;
pub const glyph_substituted: u16 = 0x10;
pub const glyph_ligated: u16 = 0x20;
pub const glyph_multiplied: u16 = 0x40;
pub const glyph_preserve: u16 = glyph_substituted | glyph_ligated | glyph_multiplied;

pub const lig_base: u8 = 0x10;

pub fn generalCategory(unicode_props: u16) unicode.GeneralCategory {
    return @fromBackingInt(@intCast(unicode_props & general_category_mask));
}

pub fn setGeneralCategory(unicode_props: *u16, category: unicode.GeneralCategory) void {
    unicode_props.* = @backingInt(category) | (unicode_props.* & (0xFF & ~general_category_mask));
}

pub fn isUnicodeMark(unicode_props: u16) bool {
    return generalCategory(unicode_props).isMark();
}

pub fn modifiedCombiningClass(unicode_props: u16) u8 {
    if (!isUnicodeMark(unicode_props)) return 0;
    return @intCast(unicode_props >> 8);
}

pub fn setModifiedCombiningClass(unicode_props: *u16, class: u8) void {
    if (!isUnicodeMark(unicode_props.*)) return;
    unicode_props.* = (@as(u16, class) << 8) | (unicode_props.* & 0xFF);
}

pub fn isDefaultIgnorable(unicode_props: u16, glyph_props: u16) bool {
    return unicode_props & ignorable != 0 and glyph_props & glyph_substituted == 0;
}

pub fn isHidden(unicode_props: u16) bool {
    return unicode_props & hidden != 0;
}

pub fn isContinuation(unicode_props: u16) bool {
    return unicode_props & continuation != 0;
}

fn isFormat(unicode_props: u16) bool {
    return generalCategory(unicode_props) == .format;
}

pub fn isZwj(unicode_props: u16) bool {
    return isFormat(unicode_props) and unicode_props & cf_zwj != 0;
}

pub fn isZwnj(unicode_props: u16) bool {
    return isFormat(unicode_props) and unicode_props & cf_zwnj != 0;
}

pub fn isVariationSelector(unicode_props: u16) bool {
    return isFormat(unicode_props) and unicode_props & cf_vs != 0;
}

pub fn isMark(glyph_props: u16) bool {
    return glyph_props & glyph_mark != 0;
}

pub fn isLigature(glyph_props: u16) bool {
    return glyph_props & glyph_ligature != 0;
}

pub fn isBaseGlyph(glyph_props: u16) bool {
    return glyph_props & glyph_base != 0;
}

pub fn ligId(lig_props: u8) u8 {
    return lig_props >> 5;
}

pub fn ligatedInternal(lig_props: u8) bool {
    return lig_props & lig_base != 0;
}

pub fn ligComp(lig_props: u8) u8 {
    if (ligatedInternal(lig_props)) return 0;
    return lig_props & 0x0F;
}

pub fn ligNumComps(lig_props: u8, glyph_props: u16) u8 {
    if (isLigature(glyph_props) and ligatedInternal(lig_props)) return lig_props & 0x0F;
    return 1;
}

pub fn ligPropsForLigature(lig_id: u8, num_comps: u32) u8 {
    return (lig_id << 5) | lig_base | @as(u8, @truncate(num_comps & 0x0F));
}

pub fn ligPropsForMark(lig_id: u8, comp: u32) u8 {
    return (lig_id << 5) | @as(u8, @truncate(comp & 0x0F));
}

pub fn ligNumCompsInLigation(lig_props: u8, glyph_props: u16) u8 {
    if (glyph_props & glyph_multiplied != 0 and ligComp(lig_props) != 0) return 0;
    return ligNumComps(lig_props, glyph_props);
}

/// Props for a codepoint before glyph mapping, see `_hb_glyph_info_set_unicode_props`.
pub fn unicodeProps(codepoint: u32) u16 {
    const category = unicode.generalCategory(codepoint);
    var result: u16 = @backingInt(category);
    if (codepoint < 0x80) return result;
    if (unicode.isDefaultIgnorable(codepoint)) {
        result |= ignorable;
        switch (codepoint) {
            0x200C => result |= cf_zwnj,
            0x200D => result |= cf_zwj,
            0x180B...0x180D, 0x180F, 0xE0020...0xE007F, 0x034F => result |= hidden,
            else => {},
        }
    }
    if (category.isMark()) {
        result |= continuation;
        result |= @as(u16, unicode.modifiedCombiningClass(codepoint)) << 8;
    }
    return result;
}
