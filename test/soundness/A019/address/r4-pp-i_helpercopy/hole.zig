// review 4: pp/i_helpercopy.zig
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
fn dup(w: *std.Io.Writer) std.Io.Writer {
    return w.*;
}
pub fn use() !usize {
    var s: Sink = .init();
    try s.interface.writeAll("x");
    var copy = dup(&s.interface);
    try copy.writeAll("y");
    return s.count + copy.end;
}
