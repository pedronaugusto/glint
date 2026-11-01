// matrix: A021 inline_loop: an inline loop over two locks keeps each guard: both held at once
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var guards: [2]L.Guard = undefined;
    inline for (.{ a, b }, 0..) |l, i| guards[i] = l.acquire();
    for (&guards) |*g| g.deinit();
}
