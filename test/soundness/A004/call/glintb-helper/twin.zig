// glint-b: A004 call (helper): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
const Plain = struct {
    v: u16,
    fn raw(p: Plain) u16 {
        return p.v;
    }
};
fn bump(x: anytype) u16 {
    return x.raw() +| 1;
}
pub fn f(p: Plain) u16 {
    return bump(p);
}
