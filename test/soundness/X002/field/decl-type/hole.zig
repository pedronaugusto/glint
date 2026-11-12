// replaces .decl of a type: any reference to it outside the package is a finding, behind a
// pointer too: no excuse is read.
const std = @import("std");

pub const State = struct {
    lock: *std.Io.Mutex,
};
