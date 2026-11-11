// twin: the guard is released before the switch continues to the prong that takes b
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn run(a: *L, b: *L, start: u8) void {
    sw: switch (start) {
        1 => {
            var gb = b.acquire();
            gb.deinit();
        },
        0 => {
            var ga = a.acquire();
            const zero = ga.value().* == 0;
            ga.deinit();
            if (zero) continue :sw 1;
        },
        else => {},
    }
}
