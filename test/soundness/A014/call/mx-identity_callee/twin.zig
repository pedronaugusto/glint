// matrix: a pointer into the caller's memory returned through a callee that gives back what it is given
fn same(p: *u32) *u32 {
    return p;
}
pub fn f(into: *u32) *u32 {
    into.* += 1;
    return same(into);
}
