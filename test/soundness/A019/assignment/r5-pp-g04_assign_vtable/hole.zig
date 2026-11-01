// review 5: pp/g04_assign_vtable.zig
const std = @import("std");
const Sink = struct {
    count: usize = 0,
    interface: std.Io.Writer,
    second: std.Io.Writer,
    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    const plain: std.Io.Writer.VTable = .{ .drain = std.Io.Writer.Discarding.drain };
    pub fn init() Sink {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = &.{} },
            .second = .{ .vtable = &plain, .buffer = &.{} },
        };
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        self.count += splat;
        return data.len;
    }
    fn swap(self: *Sink) void {
        self.second.vtable = &vtable;
    }
};
pub fn use() !usize {
    var s: Sink = .init();
    s.swap();
    try s.interface.writeAll("x");
    try s.second.writeAll("y");
    return s.count + s.interface.end + s.second.end;
}
