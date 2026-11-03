fn quiet(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}
pub const out = quiet;
