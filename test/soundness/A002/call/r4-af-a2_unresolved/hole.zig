// review 4: af/a2_unresolved.zig
const S = @import("aegis").Secret;
pub fn f(h: anytype) void {
    var copy = h.s;
    copy.deinit();
}
pub fn g(h: anytype, c: bool) void {
    var copy = if (c) h.s else h.t;
    copy.deinit();
}
pub fn caller() void {
    var h: struct { s: S(u32), t: S(u32) } = .{ .s = S(u32).init(1), .t = S(u32).init(2) };
    f(&h);
    g(&h, true);
}
