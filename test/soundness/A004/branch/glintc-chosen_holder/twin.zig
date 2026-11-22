// A004: Checked's bare value, its holder chosen by an if, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(first: bool, a: C, b: C) u32 {
    return (if (first) a else b).raw();
}
