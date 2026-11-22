// A011: std's Duration made by a decl literal, its member reached by the result type: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() std.Io.Duration {
    return .fromSeconds(1);
}
