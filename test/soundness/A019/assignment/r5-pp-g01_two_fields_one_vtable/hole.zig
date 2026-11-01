// review 5: pp/g01_two_fields_one_vtable.zig
const std = @import("std");
// One vtable installed into two Writer fields of Sink: drain is called with &s.second too, and
// recovers the Sink from it as though it were &s.interface.
const Sink = struct {
    count: usize = 0,
    interface: std.Io.Writer,
    second: std.Io.Writer,
    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    pub fn init() Sink {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = &.{} },
            .second = .{ .vtable = &vtable, .buffer = &.{} },
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
