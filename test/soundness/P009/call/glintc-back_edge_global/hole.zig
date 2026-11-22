// P009: a local's address reaches `c` only back through `a` (`c = same(a); a = same(c);
// a = &local`), a cycle whose walk meets `a` first: `c` stored into a global outlives the frame.
var g: *u32 = undefined;
fn same(p: *u32) *u32 {
    return p;
}
pub fn f() void {
    var local: u32 = 1;
    var a: *u32 = undefined;
    var c: *u32 = undefined;
    c = same(a);
    a = same(c);
    a = &local;
    g = c;
    local += 1;
}
