// A001: the id's own maker makes it.
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(n: u32) Id {
    return Id.fromRaw(n);
}
