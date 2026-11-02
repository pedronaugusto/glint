// A003: tryWrite's guard is never released (the lock stays held after return); tryWrite is no acquisition by
// AegisContract.acquisition's name list, so the leak is cleared.
const aegis = @import("aegis");
const R = aegis.SpinRwGuarded(u32);
pub fn leak(b: *R) u32 {
    var w = b.tryWrite() orelse return 0;
    return w.value().*;
}
