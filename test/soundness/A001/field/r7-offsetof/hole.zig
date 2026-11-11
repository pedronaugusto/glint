const aegis = @import("aegis");
const G = aegis.Guarded(u32);
// The guarded value reached by its offset, past the guard.
pub fn f(g: *G) u32 {
    const p: *u32 = @ptrFromInt(@intFromPtr(g) + @offsetOf(G, "data"));
    return p.*;
}
