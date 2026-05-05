const std = @import("std");
const Context = @import("Context.zig");
const Element = @import("Element.zig");
const Grid = @import("Grid.zig");

fn approxEq(a: f32, b: f32) !void {
    try std.testing.expectApproxEqAbs(a, b, 0.001);
}

fn expectRect(el: *Element, x: f32, y: f32, w: f32, h: f32) !void {
    try approxEq(el.box.x, x);
    try approxEq(el.box.y, y);
    try approxEq(el.box.w, w);
    try approxEq(el.box.h, h);
}

fn noScroll(_: *anyopaque, _: Element.Id) [2]f32 {
    return .{ 0, 0 };
}

fn runLayout(ctx: *Context) !void {
    ctx.computeSizes();
    try ctx.computeLayout(.{ .ctx = undefined, .getFn = @ptrCast(&noScroll) });
}

fn initCtx() Context {
    var ctx = Context.init(std.testing.allocator);
    ctx.reset();
    return ctx;
}

test "single fixed element" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(300) });
    defer ctx.close();

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 400, 300);
}

test "row: one fixed, one grow" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 400, 50);
    try expectRect(ctx.pool.get(1), 0, 0, 100, 50); // fixed width, grow height fills parent
    try expectRect(ctx.pool.get(2), 100, 0, 300, 50); // grows to fill remaining width
}

test "row: two grow children split space equally" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 200, 50);
    try expectRect(ctx.pool.get(2), 200, 0, 200, 50);
}

test "row: gap is accounted for in free space" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row, .gap = 10 });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // 400 - 10 gap = 390, split equally = 195 each
    try expectRect(ctx.pool.get(1), 0, 0, 195, 50);
    try expectRect(ctx.pool.get(2), 205, 0, 195, 50); // 195 + 10 gap = 205
}

test "column: one fixed, one grow" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(100), .height = .fixed(400), .direction = .column });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(100) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 100, 100);
    try expectRect(ctx.pool.get(2), 0, 100, 100, 300);
}

test "fit: parent wraps children" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fit(), .height = .fit(), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(80), .height = .fixed(40) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(120), .height = .fixed(60) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // width = 80 + 120 = 200, height = max(40, 60) = 60
    try expectRect(ctx.pool.get(root), 0, 0, 200, 60);
    try expectRect(ctx.pool.get(1), 0, 0, 80, 40);
    try expectRect(ctx.pool.get(2), 80, 0, 120, 60);
}

test "padding: offsets children and shrinks available space" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{
        .width = .fixed(400),
        .height = .fixed(200),
        .direction = .row,
        .padding = .init(10, 20, 10, 20),
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // child fills inner area: 400-40 wide, 200-20 tall, offset by padding
    try expectRect(ctx.pool.get(1), 20, 10, 360, 180);
}

test "min/max: grow does not exceed max" {
    var ctx = initCtx();
    defer ctx.deinit();

    _ = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(50), .direction = .row });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .{ .kind = .grow, .max = 100 }, .height = .fixed(50) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .fixed(50) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    // a is clamped to 100, b gets remaining 300
    try expectRect(ctx.pool.get(1), 0, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 100, 0, 300, 50);
}

test "nested: row inside column" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(400), .height = .fixed(300), .direction = .column });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .fixed(50), .direction = .row });
        defer ctx.close();
        {
            _ = try ctx.open(2, .{ .width = .fixed(100), .height = .grow() });
            defer ctx.close();
        }
        {
            _ = try ctx.open(3, .{ .width = .grow(), .height = .grow() });
            defer ctx.close();
        }
    }
    {
        _ = try ctx.open(4, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 400, 300);
    try expectRect(ctx.pool.get(1), 0, 0, 400, 50); // row
    try expectRect(ctx.pool.get(2), 0, 0, 100, 50); // a
    try expectRect(ctx.pool.get(3), 100, 0, 300, 50); // b
    try expectRect(ctx.pool.get(4), 0, 50, 400, 250); // footer grows to fill remaining
}

test "children stack at parent origin" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(200), .height = .fixed(200), .direction = .layer });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(120), .height = .fixed(80) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(60), .height = .fixed(40) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 200, 200);
    try expectRect(ctx.pool.get(1), 0, 0, 120, 80);
    try expectRect(ctx.pool.get(2), 0, 0, 60, 40);
}

test "fit parent sizes to max(child) on both axes" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fit(), .height = .fit(), .direction = .layer });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .fixed(100), .height = .fixed(80) });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .fixed(150), .height = .fixed(40) });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 150, 80);
}

test "2x2 fr tracks split parent equally" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{ .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]Grid.Track{ .{ .fr = 1 }, .{ .fr = 1 } };
    const root = try ctx.open(0, .{
        .width = .fixed(200),
        .height = .fixed(100),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .grid_placement = .{ .row = 0, .col = 0 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .grid_placement = .{ .row = 0, .col = 1 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(3, .{ .grid_placement = .{ .row = 1, .col = 0 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(4, .{ .grid_placement = .{ .row = 1, .col = 1 } });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 200, 100);
    try expectRect(ctx.pool.get(1), 0, 0, 100, 50);
    try expectRect(ctx.pool.get(2), 100, 0, 100, 50);
    try expectRect(ctx.pool.get(3), 0, 50, 100, 50);
    try expectRect(ctx.pool.get(4), 100, 50, 100, 50);
}

test "fixed + fr column with gap" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{ .{ .fixed = 60 }, .{ .fr = 1 } };
    const rows = [_]Grid.Track{.{ .fixed = 40 }};
    _ = try ctx.open(0, .{
        .width = .fixed(200),
        .height = .fixed(40),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
        .gap = 10,
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .grid_placement = .{ .row = 0, .col = 0 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .grid_placement = .{ .row = 0, .col = 1 } });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(1), 0, 0, 60, 40);
    // fr column gets remaining: 200 - 60 - 10 (gap) = 130
    try expectRect(ctx.pool.get(2), 70, 0, 130, 40);
}

test "col span covers multiple tracks" {
    var ctx = initCtx();
    defer ctx.deinit();

    const cols = [_]Grid.Track{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]Grid.Track{.{ .fixed = 50 }};
    const root = try ctx.open(0, .{
        .width = .fixed(300),
        .height = .fixed(50),
        .direction = .grid,
        .grid_template = .{ .cols = &cols, .rows = &rows },
    });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .grid_placement = .{ .row = 0, .col = 0, .col_span = 2 } });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .grid_placement = .{ .row = 0, .col = 2 } });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 300, 50);
    // Two fr columns at 100 each: 200 wide.
    try expectRect(ctx.pool.get(1), 0, 0, 200, 50);
    try expectRect(ctx.pool.get(2), 200, 0, 100, 50);
}

test "grow children fill parent independently" {
    var ctx = initCtx();
    defer ctx.deinit();

    const root = try ctx.open(0, .{ .width = .fixed(300), .height = .fixed(200), .direction = .layer });
    defer ctx.close();
    {
        _ = try ctx.open(1, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }
    {
        _ = try ctx.open(2, .{ .width = .grow(), .height = .grow() });
        defer ctx.close();
    }

    try runLayout(&ctx);

    try expectRect(ctx.pool.get(root), 0, 0, 300, 200);
    try expectRect(ctx.pool.get(1), 0, 0, 300, 200);
    try expectRect(ctx.pool.get(2), 0, 0, 300, 200);
}
