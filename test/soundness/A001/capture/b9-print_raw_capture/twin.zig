// A001: plain integers, raw values captured from an array, printed with {d}: no governed value reaches the print.
const aegis = @import("aegis");
const std = @import("std");
const Days = aegis.units.Count(enum { day }, u64);
pub fn write(w: *std.Io.Writer, d: Days, m: Days) !void {
    for ([_]u64{ d.raw(), m.raw() }, "DM") |v, c| {
        if (v != 0) try w.print("{d}{c}", .{ v, c });
    }
}
