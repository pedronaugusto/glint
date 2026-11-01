// review 4: u/h03_flags_success.zig
// held? flags and error-union success branches that do not show the write (expected: one finding each)
const std = @import("std");
fn fill(r: *std.Io.Reader, p: *[4]u8) !void {
    try r.readSliceAll(p);
}
fn maybe(p: *[4]u8, c: bool) !void {
    if (c) return;
    p.* = .{ 1, 2, 3, 4 };
}
pub fn f1(r: *std.Io.Reader) [4]u8 {
    var buf: [4]u8 = undefined;
    const ok = if (fill(r, &buf)) |_| true else |_| false;
    if (ok or r.end == 0) return buf;
    return .{ 0, 0, 0, 0 };
}
pub fn f2(r: *std.Io.Reader) [4]u8 {
    var buf: [4]u8 = undefined;
    const ok = if (fill(r, &buf)) |_| true else |_| false;
    if (!ok) return buf;
    return .{ 0, 0, 0, 0 };
}
pub fn f3(c: bool) [4]u8 {
    var buf: [4]u8 = undefined;
    if (maybe(&buf, c)) |_| return buf else |_| return .{ 0, 0, 0, 0 };
}
pub fn f4(r: *std.Io.Reader) [4]u8 {
    var buf: [4]u8 = undefined;
    const ok = if (fill(r, &buf)) |_| false else |_| true;
    if (ok) return .{ 0, 0, 0, 0 };
    return buf;
}
pub fn f5(r: *std.Io.Reader, c: bool) [4]u8 {
    var buf: [4]u8 = undefined;
    const ok = c or if (fill(r, &buf)) |_| true else |_| false;
    if (ok) return buf;
    return .{ 0, 0, 0, 0 };
}
pub fn f6(r: *std.Io.Reader) [4]u8 {
    var buf: [4]u8 = undefined;
    if (fill(r, &buf)) |_| {} else |_| {}
    return buf;
}
