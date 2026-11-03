// A010: a vtable's read, which does not resolve, is handed the reader: what it returns may be the peer's number, whose product overflows
const std = @import("std");
pub const Source = struct {
    read: *const fn (*std.Io.Reader) anyerror!u64,
};
pub fn f(r: *std.Io.Reader, source: *const Source) !u64 {
    const v = try source.read(r);
    return v * 3;
}
