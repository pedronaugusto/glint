// A004: Checked's bare value, its holder a comptime constant, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
const limit: C = .init(9);
pub fn f() u32 {
    return limit.raw();
}
