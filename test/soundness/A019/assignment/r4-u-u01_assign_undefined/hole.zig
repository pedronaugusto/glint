// review 4: u/u01_assign_undefined.zig
// A019: assigning `undefined` counts as writing the local.
pub fn f(c: bool) u32 {
    var x: u32 = undefined;
    if (c) x = 1;
    x = undefined;
    return x + 1;
}
