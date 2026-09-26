pub const Rect = @import("Rect.zig");
pub const Text = @import("Text.zig");
pub const Button = @import("Button.zig");
pub const MenuButton = @import("MenuButton.zig").MenuButton;
pub const Spacer = @import("Spacer.zig");
pub const TextInput = @import("TextInput.zig");
pub const TextArea = @import("TextArea.zig");
pub const SelectInput = @import("select_input.zig").SelectInput;
pub const SliderInput = @import("SliderInput.zig");
pub const ProgressBar = @import("ProgressBar.zig");
pub const ColorPicker = @import("ColorPicker.zig");
pub const Checkbox = @import("Checkbox.zig");
pub const Tooltip = @import("Tooltip.zig");
pub const RadioButton = @import("radio.zig").RadioButton;
pub const RadioGroup = @import("radio.zig").RadioGroup;
pub const Canvas = @import("Canvas.zig");
pub const Image = @import("Image.zig");
pub const Graph = @import("Graph.zig");
pub const Dialog = @import("Dialog.zig");
pub const FloatingWindow = @import("FloatingWindow.zig");
pub const ContextMenu = @import("ContextMenu.zig").ContextMenu;
pub const Collapsible = @import("Collapsible.zig");
pub const GPUCanvas = @import("GPUCanvas.zig");

// ── Component contract lint (see docs/style-engine.md §8)

const std = @import("std");
const layout = @import("layout");
const style = @import("style");

const Dummy = struct {
    pub fn open(_: *const Dummy, _: *@import("../root.zig").Frame) !layout.Element.Id {
        return layout.Element.INVALID_ID;
    }
    pub fn close(_: *const Dummy, _: *@import("../root.zig").Frame) !void {}
};
const DummyOption = enum { a, b };

const linted = .{
    Rect,
    Text,
    Button,
    MenuButton(Dummy),
    Spacer,
    TextInput,
    TextArea,
    SelectInput(DummyOption),
    SliderInput,
    ProgressBar,
    ColorPicker,
    Checkbox,
    Tooltip,
    RadioButton(DummyOption),
    RadioGroup(DummyOption),
    Canvas,
    Image,
    Graph,
    Dialog,
    FloatingWindow,
    ContextMenu(Dummy),
    Collapsible,
    GPUCanvas,
};

/// Types that only `style` or `parts` may carry.
const styling_types = .{
    style.Color.Input,
    style.Color,
    [4]f32,
    style.Radius.Input,
    style.BorderWidth,
    style.FontSize.Input,
    layout.Element.Padding,
    layout.Element.sizing.Axis,
    layout.Element.Align,
    layout.Element.Justify,
    layout.Element.Direction,
    layout.Element.Overflow,
    layout.Element.Position,
    layout.Layer,
    layout.Grid.Template,
    layout.Grid.Placement,
    layout.Grid.Track,
};

fn isStylingType(comptime T: type) bool {
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    inline for (styling_types) |S| if (Base == S) return true;
    return false;
}

fn lintComponent(comptime C: type, report: bool) !void {
    const name = @typeName(C);
    if (!@hasField(C, "style") or @FieldType(C, "style") != *const style.Style) {
        if (report) std.debug.print("{s}: missing `style: *const Style`\n", .{name});
        return error.ComponentContract;
    }
    if (!@hasDecl(C, "base") or !@hasDecl(C.base, "root") or @TypeOf(C.base.root) != style.Style) {
        if (report) std.debug.print("{s}: missing `base.root: Style`\n", .{name});
        return error.ComponentContract;
    }

    const info = @typeInfo(C).@"struct";
    var base_count: usize = 1;
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (comptime std.mem.eql(u8, field_name, "parts")) {
            if (!@hasDecl(C, "Parts") or Field != C.Parts) {
                if (report) std.debug.print("{s}: `parts` must be of type `Parts`\n", .{name});
                return error.ComponentContract;
            }
            const parts = @typeInfo(C.Parts).@"struct";
            inline for (parts.field_names, parts.field_types) |part_name, Part| {
                if (Part != *const style.Style) {
                    if (report) std.debug.print("{s}: part `{s}` is not `*const Style`\n", .{ name, part_name });
                    return error.ComponentContract;
                }
                if (!@hasDecl(C.base, part_name) or @TypeOf(@field(C.base, part_name)) != style.Style) {
                    if (report) std.debug.print("{s}: missing `base.{s}: Style`\n", .{ name, part_name });
                    return error.ComponentContract;
                }
                base_count += 1;
            }
        } else if (comptime isStylingType(Field)) {
            if (report) std.debug.print("{s}: styling field `{s}` outside `style` / `parts`\n", .{ name, field_name });
            return error.ComponentContract;
        }
    }
    if (@typeInfo(C.base).@"struct".decl_names.len != base_count) {
        if (report) std.debug.print("{s}: `base` must declare exactly `root` plus each `Parts` field\n", .{name});
        return error.ComponentContract;
    }
}

test "components follow the styling contract" {
    inline for (linted) |C| try lintComponent(C, true);
}

test "lint rejects component-specific styling fields" {
    const Bad = struct {
        key: @import("../root.zig").Key,
        style: *const style.Style = &.{},
        popup_padding: layout.Element.Padding = .all(4),
        pub const base = struct {
            pub const root: style.Style = .{};
        };
    };
    try std.testing.expectError(error.ComponentContract, lintComponent(Bad, false));
}
