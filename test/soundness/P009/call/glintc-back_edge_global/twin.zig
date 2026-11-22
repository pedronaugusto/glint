// P009: the same cycle carrying a global's address: what `c` holds outlives the call.
var g: *u32 = undefined;
var kept: u32 = 0;
fn same(p: *u32) *u32 {
    return p;
}
pub fn f() void {
    var a: *u32 = undefined;
    var c: *u32 = undefined;
    c = same(a);
    a = same(c);
    a = &kept;
    g = c;
}
