// matrix: A021 inline_loop: an inline loop over two locks releases each guard in its pass
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    inline for (.{ a, b }) |l| {
        var g = l.acquire();
        g.value().* += 1;
        g.deinit();
    }
}
