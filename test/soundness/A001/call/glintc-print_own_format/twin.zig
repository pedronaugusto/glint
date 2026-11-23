// A001: a governed value printed by `{f}`, its type's own format, the exit aegis gives for text,
// and by `{*}`, its address: std reads none of its fields (reactor's Records, main's ruling).
const std = @import("std");
const aegis = @import("aegis");
pub fn report(w: *std.Io.Writer, high: u64, parked: usize) !void {
    const bytes = aegis.units.Bytes(u64).fromRaw(high);
    try w.print("parked={d} high={f} at={*}\n", .{ parked, bytes, &bytes });
}
