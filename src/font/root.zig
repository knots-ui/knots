pub const FontProgram = @import("FontProgram.zig");
pub const Reader = @import("Reader.zig");
pub const sfnt = @import("sfnt.zig");
pub const Cmap = @import("Cmap.zig");
pub const Gdef = @import("Gdef.zig");
pub const Layout = @import("Layout.zig");
pub const Partition = @import("Partition.zig");
pub const coverage = @import("coverage.zig");
pub const class_def = @import("class_def.zig");
pub const Kern = @import("Kern.zig");
pub const Colr = @import("Colr.zig");
pub const Outline = @import("Outline.zig");
pub const Cff = @import("Cff.zig");
pub const participation = @import("participation.zig");

test {
    _ = FontProgram;
    _ = Reader;
    _ = sfnt;
    _ = Cmap;
    _ = Layout;
    _ = coverage;
    _ = Colr;
    _ = Outline;
    _ = Cff;
}
