// matrix: a local pointer given the frame's address through a pointer to it, then returned
pub fn f() *u32 {
    var x: u32 = 1;
    x += 1;
    var p: *u32 = undefined;
    const into = &p;
    into.* = &x;
    return p;
}
