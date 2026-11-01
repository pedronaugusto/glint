const std = @import("std");
var shared: std.Io.Mutex = .init;
pub fn maybe(wanted: bool) ?std.Io.Mutex {
    return if (wanted) .init else null;
}
pub fn maybeShared(wanted: bool) ?*std.Io.Mutex {
    return if (wanted) &shared else null;
}
