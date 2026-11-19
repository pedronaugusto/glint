// A004: the same const locals handed to a call are no arithmetic, comparison or narrowing cast here.
const aegis = @import("aegis");
pub fn f(a: aegis.int.Checked(u32), b: aegis.int.Checked(u32)) u64 {
    const x = a.raw();
    const y = b.raw();
    return widened(x, y);
}
fn widened(x: u32, y: u32) u64 {
    return @as(u64, x) + y;
}
