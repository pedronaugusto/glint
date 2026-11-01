// review 5: pp/g01b_two_fields_two_vtables.zig
const std = @import("std");
const Sink = struct {
    count: usize = 0,
    interface: std.Io.Writer,
    second: std.Io.Writer,
    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    const vtable2: std.Io.Writer.VTable = .{ .drain = drain2 };
    pub fn init() Sink {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = &.{} },
            .second = .{ .vtable = &vtable2, .buffer = &.{} },
        };
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        self.count += splat;
        return data.len;
    }
    fn drain2(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("second", w));
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
