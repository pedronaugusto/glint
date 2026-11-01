const std = @import("std");
pub fn maybe(wanted: bool) ?std.Io.Mutex {
    return if (wanted) .init else null;
}
