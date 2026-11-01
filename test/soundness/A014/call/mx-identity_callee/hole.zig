// matrix: a pointer into the frame returned through a callee that gives back what it is given
fn same(p: *u32) *u32 {
    return p;
}
pub fn f() *u32 {
    var x: u32 = 1;
    x += 1;
    return same(&x);
}
