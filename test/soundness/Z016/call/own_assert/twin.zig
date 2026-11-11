// twin: the project's own `assert`, which does not resolve to std's
fn assert(ok: bool) void {
    if (!ok) unreachable;
}
pub fn check(a: bool, b: bool) void {
    assert(a and b);
}
