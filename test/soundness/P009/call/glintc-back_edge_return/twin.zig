// P009: the same cycle carrying a global's address: returned, it outlives the call.
var kept: u32 = 0;
fn same(p: *u32) *u32 {
    return p;
}
pub fn f() *u32 {
    var a: *u32 = undefined;
    var c: *u32 = undefined;
    c = same(a);
    a = same(c);
    a = &kept;
    return c;
}
