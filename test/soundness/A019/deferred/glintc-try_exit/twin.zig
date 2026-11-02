// A019 deferred: the write comes before the `try`, so every exit's deferred read reads a value
fn keep(v: u32) void {
    _ = v;
}
fn may() !void {}
pub fn writeBeforeTry() !void {
    var x: u32 = undefined;
    defer keep(x);
    x = 1;
    try may();
}
