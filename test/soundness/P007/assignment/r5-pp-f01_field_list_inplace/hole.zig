// review 5: pp/f01_field_list_inplace.zig
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
    var total: usize = 0;
    inline for (.{ "count", "interface" }) |name| {
        var copy = @field(s, name);
        if (@TypeOf(copy) == std.Io.Writer) {
            try copy.writeAll("y");
            total += copy.end;
        }
    }
    return total + s.count;
}
