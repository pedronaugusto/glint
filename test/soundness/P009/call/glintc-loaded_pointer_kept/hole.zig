// P009: the callee keeps a pointer it reads through the one it is given, and that pointer is
// into the caller's local array.
const S = struct { p: *[4]u8 };
const G = struct { p: ?*[4]u8 = null };
fn keep(g: *G, s: *S) void {
    g.p = s.p;
}
pub fn f(g: *G) void {
    var arr: [4]u8 = .{ 1, 2, 3, 4 };
    var s: S = .{ .p = &arr };
    keep(g, &s);
}
