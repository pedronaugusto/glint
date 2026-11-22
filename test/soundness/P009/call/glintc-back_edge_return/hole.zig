// P009: a local's address reaches `c` only back through `a` (`c = same(a); a = same(c);
// a = &local`), a cycle whose walk meets `a` first: `c` returned, the return frees it.
fn same(p: *u32) *u32 {
    return p;
}
pub fn f() *u32 {
    var local: u32 = 1;
    var a: *u32 = undefined;
    var c: *u32 = undefined;
    c = same(a);
    a = same(c);
    a = &local;
    local += 1;
    return c;
}
