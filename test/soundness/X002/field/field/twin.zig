// replaces .field: another field of the same type is no finding.
const std = @import("std");

pub fn f(r: *const std.Io.Reader) usize {
    return r.seek;
}
