// review 4: u/u02b_baseline.zig
// baseline: one field never set (expected flagged)
const S = struct { a: u32, b: u32 };
pub fn f() u32 {
    var s: S = undefined;
    s.a = 1;
    return s.a + s.b;
}
