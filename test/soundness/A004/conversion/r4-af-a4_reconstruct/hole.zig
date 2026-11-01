// review 4: af/a4_reconstruct.zig
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
const NZ = aegis.id.NonZero(struct {}, u16);
const Box = struct { v: u16 };
fn add1(v: u16) u16 {
    return v + 1;
}
var global: u16 = 0;
pub fn f(v: u16) NZ {
    return @enumFromInt(v);
}
