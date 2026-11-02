// The same, its type declared public.
const std = @import("std");
pub const Hidden = (struct { x: u8 });
pub fn make() std.ArrayList(Hidden) {
    return .empty;
}
