//! Pure styling module: value types, the `Style` vocabulary, theme tokens and
//! the resolver. No runtime state, time, input or rendering.
pub const Style = @import("Style.zig");
pub const Color = @import("Color.zig");
pub const Radius = @import("Radius.zig");
pub const BorderWidth = @import("BorderWidth.zig");
pub const FontSize = @import("FontSize.zig");
pub const Theme = @import("Theme.zig");

pub const Tone = Color.Tone;
pub const States = Style.States;
pub const Transition = Style.Transition;
pub const Surface = Style.Surface;
pub const Content = Style.Content;
pub const Layout = Style.Layout;
pub const Visual = Style.Visual;
pub const Resolved = Style.Resolved;
pub const Cascade = Style.Cascade;

pub const resolve = Style.resolve;
pub const rootContent = Style.rootContent;

test {
    _ = @import("tests.zig");
}
