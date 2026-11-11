// replaces .field: a read of the field, by its declaration in its type, is a finding.
const std = @import("std");

pub fn f(r: *const std.Io.Reader) []u8 {
    return r.buffer;
}
