// matrix: A021 memory: a guard copied by @memcpy out of a block into a local outside it, still held when the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var kept: [1]L.Guard = undefined;
    {
        const taken = [1]L.Guard{a.acquire()};
        @memcpy(&kept, &taken);
    }
    var gb = b.acquire();
    defer gb.deinit();
    kept[0].deinit();
}
