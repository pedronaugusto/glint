// matrix: A021 jump: the guard a labeled block's break carries, released before the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = blk: {
        break :blk a.acquire();
    };
    ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
