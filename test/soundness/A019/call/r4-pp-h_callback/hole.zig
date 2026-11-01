// review 4: pp/h_callback.zig
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
fn call(f: *const fn (*std.Io.Writer, []const []const u8, usize) std.Io.Writer.Error!usize, w: *std.Io.Writer) !usize {
    return f(w, &.{}, 1);
}
pub fn use() !usize {
    var w: std.Io.Writer = .fixed(&.{});
    _ = try call(Sink.drain, &w);
    var s: Sink = .init();
    try s.interface.writeAll("x");
    return s.count + s.interface.end;
}
