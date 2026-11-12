// A001: @fromBackingInt makes a governed id from an integer without its makers (review 8, C1).
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(n: u32) Id {
    return @fromBackingInt(n);
}
