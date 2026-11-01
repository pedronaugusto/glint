// review 5: pp/g02_drain_direct_field.zig
const std = @import("std");
// drain installed directly in a VTable literal held in the second field.
const Sink = struct {
    count: usize = 0,
    interface: std.Io.Writer,
    second: std.Io.Writer,
    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    const other: std.Io.Writer.VTable = .{ .drain = drain };
    pub fn init() Sink {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = &.{} },
            .second = .{ .vtable = &other, .buffer = &.{} },
        };
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        self.count += splat;
        return data.len;
    }
};
pub fn use() !usize {
    var s: Sink = .init();
    try s.interface.writeAll("x");
    try s.second.writeAll("y");
    return s.count + s.interface.end + s.second.end;
}
