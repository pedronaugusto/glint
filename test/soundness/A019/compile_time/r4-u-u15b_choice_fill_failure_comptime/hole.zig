// review 4: u/u15b_choice_fill_failure_comptime.zig
// A019 (strict-review chosen()): the same choice made by a comptime flag of the program's own.
const std = @import("std");
const use_random = false;
const Src = if (use_random) std.Io else *std.Io.Reader;
const fill = if (use_random) std.Io.random else std.Io.Reader.readSliceAll;
pub fn get(src: Src) u8 {
    var buf: [16]u8 = undefined;
    fill(src, &buf) catch {};
    return buf[15];
}
