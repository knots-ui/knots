const std = @import("std");

pub const TimestampFormatter = struct {
    value: std.Io.Timestamp,

    pub fn format(self: TimestampFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const seconds_since_epoch = self.value.toSeconds();
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds_since_epoch) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        const milliseconds_since_epoch = self.value.toMilliseconds();
        const milliseconds = @as(u64, @intCast(@mod(milliseconds_since_epoch, 1000)));

        try writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
            .{
                year_day.year,
                month_day.month.numeric(),
                @as(u32, month_day.day_index) + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
                milliseconds,
            },
        );
    }
};

pub const IdListFormatter = struct {
    ids: []const []const u8,

    pub fn format(self: IdListFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('[');
        for (self.ids, 0..) |id, index| {
            std.debug.assert(id.len > 0);
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll(id);
        }
        try writer.writeByte(']');
    }
};

pub fn timestamp(io: std.Io) TimestampFormatter {
    return .{ .value = std.Io.Clock.real.now(io) };
}

pub fn elapsedMilliseconds(io: std.Io, started_at: std.Io.Timestamp) u64 {
    const elapsed = started_at.durationTo(std.Io.Clock.awake.now(io));
    const milliseconds = elapsed.toMilliseconds();
    return @intCast(milliseconds);
}

test "timestamp formatter uses UTC and milliseconds" {
    try std.testing.expectFmt(
        "1970-01-01T00:00:01.234Z",
        "{f}",
        .{TimestampFormatter{ .value = std.Io.Timestamp.fromNanoseconds(1_234_000_000) }},
    );
}

test "empty ID lists remain structured" {
    try std.testing.expectFmt("[]", "{f}", .{IdListFormatter{ .ids = &.{} }});
}
