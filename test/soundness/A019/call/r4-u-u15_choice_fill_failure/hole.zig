// review 4: u/u15_choice_fill_failure.zig
// A019 (strict-review chosen()): a per-build choice of two std fills; the first (Io.random) cannot
// fail, the one this build takes (readSliceAll) can, and its error is discarded.
const std = @import("std");
const builtin = @import("builtin");
const Src = if (builtin.os.tag == .windows) std.Io else *std.Io.Reader;
const fill = if (builtin.os.tag == .windows) std.Io.random else std.Io.Reader.readSliceAll;
pub fn get(src: Src) u8 {
    var buf: [16]u8 = undefined;
    fill(src, &buf) catch {};
    return buf[15];
}
