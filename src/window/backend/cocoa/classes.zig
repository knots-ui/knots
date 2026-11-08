const objc = @import("objc");
const ak = @import("appkit.zig");
const events = @import("events.zig");
const text_input = @import("text_input.zig");

pub const Registered = struct {
    view: objc.Class,
    delegate: objc.Class,
};

pub fn registerClasses() !Registered {
    const view_class = try registerView();
    const delegate_class = try registerDelegate();
    return .{ .view = view_class, .delegate = delegate_class };
}

fn registerView() !objc.Class {
    const NSView = objc.getClass("NSView").?;
    const cls = objc.allocateClassPair(NSView, "KnotsView") orelse return error.AllocateClassFailed;
    if (!ak.addOwnerIvar(cls)) return error.AddIvarFailed;
    const methods = events.view_misc_methods ++ events.mouse_methods ++
        events.keyboard_methods ++ events.drag_methods ++ text_input.text_input_methods;

    inline for (methods) |entry| if (!cls.addMethod(entry[0], entry[1])) return error.AddMethodFailed;
    if (!text_input.adoptProtocol(cls)) return error.AddProtocolFailed;

    objc.registerClassPair(cls);
    return cls;
}

fn registerDelegate() !objc.Class {
    const NSObject = objc.getClass("NSObject").?;
    const cls = objc.allocateClassPair(NSObject, "KnotsWindowDelegate") orelse return error.AllocateClassFailed;
    if (!ak.addOwnerIvar(cls)) return error.AddIvarFailed;
    inline for (events.delegate_methods) |entry| {
        if (!cls.addMethod(entry[0], entry[1])) return error.AddMethodFailed;
    }
    objc.registerClassPair(cls);
    return cls;
}
