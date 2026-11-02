// A019 deferred: given undefined again after the defer, the local is written again before the exit
fn keep(v: u32) void {
    _ = v;
}
pub fn writtenAgain() void {
    var x: u32 = undefined;
    x = 1;
    defer keep(x);
    x = undefined;
    x = 2;
}
