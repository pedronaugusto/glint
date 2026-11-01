// review 4: pp/h_fnarray.zig
const std = @import("std");
const Sink = struct {
    count: usize = 0,
    interface: std.Io.Writer,
    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    pub fn init() Sink {
        return .{ .interface = .{ .vtable = &vtable, .buffer = &.{} } };
    }
    const fns = [_]*const fn (*std.Io.Writer, []const []const u8, usize) std.Io.Writer.Error!usize{drain};
    pub fn first() *const fn (*std.Io.Writer, []const []const u8, usize) std.Io.Writer.Error!usize {
        return fns[0];
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
    return s.count + s.interface.end;
}
