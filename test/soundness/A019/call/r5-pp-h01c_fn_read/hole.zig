// review 5: pp/h01c_fn_read.zig
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
pub fn use(other: *std.Io.Writer) !usize {
    var s: Sink = .init();
    try s.interface.writeAll("x");
    const f = s.interface.vtable.drain;
    _ = try f(other, &.{"y"}, 1);
    return s.count;
}
