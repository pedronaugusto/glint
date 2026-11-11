// A021: a labeled switch is a loop: the prong that holds a's guard continues to an earlier prong, which takes b while a is held
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
            if (ga.value().* == 0) continue :sw 1;
            ga.deinit();
        },
        else => {},
    }
}
