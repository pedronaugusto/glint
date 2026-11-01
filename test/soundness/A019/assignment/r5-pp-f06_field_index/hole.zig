// review 5: pp/f06_field_index.zig
const std = @import("std");
const Sink = struct {
    count: usize = 0,
    interface: std.Io.Writer,
    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    pub fn init() Sink {
        return .{ .interface = .{ .vtable = &vtable, .buffer = &.{} } };
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        self.count += splat;
        return data.len;
    }
};
const names = [_][]const u8{ "count", "interface" };
pub fn use() !usize {
    var s: Sink = .init();
    try s.interface.writeAll("x");
    var copy = @field(s, names[1]);
    try copy.writeAll("y");
    return copy.end + s.count;
}
