const std = @import("std");

/// Whether an error set names `Timeout`, read off its type information.
pub fn timesOut(comptime E: type) bool {
    const names = @typeInfo(E).error_set.error_names orelse return false;
    inline for (names) |name| if (comptime std.mem.eql(u8, name, "Timeout")) return true;
    return false;
}

pub fn readTimesOut() bool {
    return timesOut(error{ Timeout, Closed });
}
