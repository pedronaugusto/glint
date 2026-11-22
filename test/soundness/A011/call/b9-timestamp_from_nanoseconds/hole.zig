// A011: an instant made by hand from a raw count, its clock dropped: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn at(n: i96) std.Io.Timestamp {
    return std.Io.Timestamp.fromNanoseconds(n);
}
