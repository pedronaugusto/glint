// review 4: u/u02_part_undefined.zig
// A019: a field set to `undefined` counts as that part written; all parts "written" = whole.
const S = struct { a: u32, b: u32 };
pub fn f() u32 {
    var s: S = undefined;
    s.a = 1;
    s.b = undefined;
    return s.a + s.b;
}
