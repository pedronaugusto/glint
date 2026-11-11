const aegis = @import("aegis");
const b = @import("b.zig");
// A generic in another program file reads the guarded value when bound with the guard's owner.
pub fn f(g: *aegis.Guarded(u32)) u32 {
    return b.peek(g);
}
