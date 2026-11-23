// A001: a governed value printed through a format that is not written as a literal: what it
// writes for the value is not read, so it is a finding.
const std = @import("std");
const aegis = @import("aegis");
pub fn report(w: *std.Io.Writer, comptime format: []const u8, high: u64) !void {
    const bytes = aegis.units.Bytes(u64).fromRaw(high);
    try w.print(format, .{bytes});
}
