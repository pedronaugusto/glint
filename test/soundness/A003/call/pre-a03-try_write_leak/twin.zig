const aegis = @import("aegis");
const R = aegis.SpinRwGuarded(u32);
pub fn leak(b: *R) u32 {
    var w = b.tryWrite() orelse return 0;
    defer w.deinit();
    return w.value().*;
}
