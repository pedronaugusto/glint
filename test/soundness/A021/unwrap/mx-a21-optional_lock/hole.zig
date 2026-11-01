// matrix: A021 unwrap: the second lock unwrapped from an optional pointer by .?, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: ?*L) void {
    var ga = a.acquire();
    defer ga.deinit();
    var gb = b.?.acquire();
    defer gb.deinit();
}
