// replaces .held = .field: a field behind a pointer, a local and a parameter hold none by value
// in a field: no finding.
const std = @import("std");

pub const Log = struct {
    file: *std.Io.File,
};

pub fn f(file: std.Io.File) std.Io.File {
    const same: std.Io.File = file;
    return same;
}
