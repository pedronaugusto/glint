// A004: Checked's bare value, its holder unwrapped from an optional by .?, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(given: ?C) u32 {
    return given.?.raw();
}
