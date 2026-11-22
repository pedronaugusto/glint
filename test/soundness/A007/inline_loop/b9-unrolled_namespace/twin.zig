// A007: aegis an unrolled loop's capture, its guard made through it: none.
const aegis = @import("aegis");
pub fn make() u32 {
    var total: u32 = 0;
    inline for (.{aegis}) |sync| {
        var guarded: sync.Guarded(u32) = .init(1);
        var guard = guarded.acquire();
        defer guard.deinit();
        total += guard.value().*;
    }
    return total;
}
