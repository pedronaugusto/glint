// matrix: A021 destructure: two guards taken in one tuple and destructured into two locals
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga, var gb = .{ a.acquire(), b.acquire() };
    defer ga.deinit();
    defer gb.deinit();
}
