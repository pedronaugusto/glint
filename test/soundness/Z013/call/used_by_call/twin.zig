// matrix: Z013 call: a private import used by a call of its function
const extra = @import("extra.zig");
pub fn value() u8 {
    return extra.get();
}
