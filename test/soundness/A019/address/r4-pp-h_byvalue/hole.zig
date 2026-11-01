// review 4: pp/h_byvalue.zig
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
fn byval(w: std.Io.Writer) usize {
    var copy = w;
    copy.writeAll("z") catch return 0;
    return copy.end;
}
pub fn use() !usize {
    var s: Sink = .init();
    try s.interface.writeAll("x");
    return s.count + byval(s.interface);
}
