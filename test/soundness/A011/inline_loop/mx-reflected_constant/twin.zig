// matrix: aegis's conversion in an inline loop over the units it converts to
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, u32);
pub fn f(ms: Ms) u64 {
    var ns: u64 = 0;
    inline for (.{aegis.units.Unit.nanosecond}) |unit| {
        ns = ms.convert(unit, u64, .exact).raw();
    }
    return ns;
}
