// matrix: A021 jump: a guard carried out of a labeled block by its break, still held when the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = blk: {
        break :blk a.acquire();
    };
    defer ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
