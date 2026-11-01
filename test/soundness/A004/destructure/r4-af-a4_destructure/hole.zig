// review 4: af/a4_destructure.zig
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
const NZ = aegis.id.NonZero(struct {}, u16);
const Box = struct { v: u16 };
fn add1(v: u16) u16 {
    return v + 1;
}
var global: u16 = 0;
pub fn f(i: Index) u16 {
    const a, const b = .{ i.raw(), @as(u16, 0) };
    return a + b;
}
