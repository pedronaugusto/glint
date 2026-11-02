// A019 deferred: a failing `try` before the write leaves by the deferred read with the local undefined
fn keep(v: u32) void {
    _ = v;
}
fn may() !void {}
pub fn tryBeforeWrite() !void {
    var x: u32 = undefined;
    defer keep(x);
    try may();
    x = 1;
}
