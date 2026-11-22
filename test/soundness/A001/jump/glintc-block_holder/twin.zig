// A001: a labeled block's break gives the holder, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    const held = blk: {
        break :blk s;
    };
    return held.expose().*;
}
