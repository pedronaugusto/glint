// A019 deferred: a deferred statement reads the local at the scope's exit, after the write
fn keep(p: *const u32) void {
    _ = p;
}
pub fn deferredRead() u32 {
    var x: u32 = undefined;
    defer keep(&x);
    x = 1;
    return x;
}
