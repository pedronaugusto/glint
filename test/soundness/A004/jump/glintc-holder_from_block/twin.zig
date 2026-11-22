// A004: Checked's bare value, its holder a labeled block's result, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(c: C) u32 {
    const held = blk: {
        break :blk c;
    };
    return held.raw();
}
