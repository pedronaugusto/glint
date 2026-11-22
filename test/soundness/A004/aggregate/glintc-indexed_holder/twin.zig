// A004: Checked's bare value, its holder an array's element, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(pair: [2]C) u32 {
    return pair[1].raw();
}
