// A001: the id's own exit reads the same integer.
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(i: Id) u32 {
    return i.raw();
}
