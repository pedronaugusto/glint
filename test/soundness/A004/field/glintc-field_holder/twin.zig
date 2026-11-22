// A004: Checked's bare value, its holder a struct's field, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
const S = struct { count: C };
pub fn f(s: S) u32 {
    return s.count.raw();
}
