// review 4: pp/i_swap.zig
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
pub fn use() !usize {
    var s: Sink = .init();
    try s.interface.writeAll("x");
    var w: std.Io.Writer = .fixed(&.{});
    std.mem.swap(std.Io.Writer, &w, &s.interface);
    try w.writeAll("y");
    return s.count + w.end;
}
