// A019 deferred: the deferred read runs at the scope's exit, after the local is given undefined again
fn keep(v: u32) void {
    _ = v;
}
pub fn unsetAfterDefer() void {
    var x: u32 = undefined;
    x = 1;
    defer keep(x);
    x = undefined;
}
