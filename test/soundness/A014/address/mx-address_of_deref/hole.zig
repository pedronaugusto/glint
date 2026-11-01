// matrix: `&p.*` of a local pointer into the frame: the same pointer, by another path
pub fn f() *u32 {
    var x: u32 = 1;
    x += 1;
    const p = &x;
    return &p.*;
}
