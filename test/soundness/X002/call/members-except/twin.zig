// replaces .members: a member `.except` names, and the container's own name, are no finding.
const std = @import("std");

pub fn f(bytes: []const u8) std.Io.Reader {
    return .fixed(bytes);
}
