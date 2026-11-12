// replaces .held = .field: a field holding the type by value is a finding, an optional one too.
const std = @import("std");

pub const Log = struct {
    file: std.Io.File,
    spare: ?std.Io.File = null,
};
