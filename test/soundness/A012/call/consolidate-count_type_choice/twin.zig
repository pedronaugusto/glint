// consolidate: the same number checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const n = try r.takeInt(u32, .little);
    try limit.check(n);
    try dep.fill(w, n);
}
