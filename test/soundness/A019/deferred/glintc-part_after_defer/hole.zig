// A019 deferred: a field given undefined after the defer is read whole at the scope's exit
const P = struct { a: u32, b: u32 };
fn keep(v: P) void {
    _ = v;
}
pub fn partUnsetAfterDefer() void {
    var p: P = undefined;
    p = .{ .a = 1, .b = 2 };
    defer keep(p);
    p.b = undefined;
}
