// A001: @backingInt over a governed id reads its integer without its API (review 8, C1).
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(i: Id) u32 {
    return @backingInt(i);
}
