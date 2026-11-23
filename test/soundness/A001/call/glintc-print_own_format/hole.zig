// A001: a governed value printed by `{any}`: std writes it field by field.
const std = @import("std");
const aegis = @import("aegis");
pub fn report(w: *std.Io.Writer, high: u64, parked: usize) !void {
    const bytes = aegis.units.Bytes(u64).fromRaw(high);
    try w.print("parked={d} high={any}\n", .{ parked, bytes });
}
