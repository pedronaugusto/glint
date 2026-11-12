// A012 (opt-in): std's own deprecated alias of a list that grows without a stated limit (review 8, M6).
const aegis = @import("aegis");
const std = @import("std");
pub fn f() std.ArrayListUnmanaged(u8) {
    return .empty;
}
