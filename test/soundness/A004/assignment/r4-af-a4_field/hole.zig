// review 4: af/a4_field.zig
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
const NZ = aegis.id.NonZero(struct {}, u16);
const Box = struct { v: u16 };
fn add1(v: u16) u16 {
    return v + 1;
}
var global: u16 = 0;
pub fn f(i: Index) u16 {
    var b: Box = .{ .v = 0 };
    b.v = i.raw();
    return b.v + 1;
}
