pub const TrackKind = enum {
    fixed,
    /// Fractional unit.
    fr,
};

pub const Track = union(TrackKind) {
    fixed: f32,
    fr: f32,
};

pub const Template = struct {
    rows: []const Track = &.{},
    cols: []const Track = &.{},
};

pub const Placement = struct {
    row: u32 = 0,
    col: u32 = 0,
    row_span: u32 = 1,
    col_span: u32 = 1,
};
