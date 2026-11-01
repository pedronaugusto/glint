// warp-fast: through the pointer, a guard returns the cause before the failure is mapped
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) error{ Canceled, Gone }!u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    const p = &r;
    return p.*.interface.takeByte() catch {
        if (p.err) |cause| if (cause == error.Canceled) return error.Canceled;
        return error.Gone;
    };
}
