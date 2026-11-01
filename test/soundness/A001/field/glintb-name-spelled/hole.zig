// glint-b: A001 field (name spelled): the unsafe shape, which must flag
const aegis = @import("aegis");
const name = "\x64ata";
pub fn f(g: *aegis.Guarded(u32)) u32 {
    return @field(g, name);
}
