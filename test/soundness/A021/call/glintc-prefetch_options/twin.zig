// A021: @prefetch's options written as a literal, `.{ .rw = .write }`: an enum literal whose
// place glint does not read spells no lock (warp's match finders, review packages).
const aegis = @import("aegis");
pub fn warm(table: []u32, i: usize) void {
    @prefetch(&table[i], .{ .rw = .write });
}
