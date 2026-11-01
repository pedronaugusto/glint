// review 4: af/a15_tuple.zig
const std = @import("std");
const File = std.Io.File;
pub const S = struct { pair: struct { std.Io.File, u32 } };
