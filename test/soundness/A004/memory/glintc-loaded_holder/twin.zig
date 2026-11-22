// A004: Checked's bare value, its holder loaded from a slice in memory, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(items: []const C) u32 {
    return items[0].raw();
}
