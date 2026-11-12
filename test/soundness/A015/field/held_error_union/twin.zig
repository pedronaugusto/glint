// A015: an error union of a borrowed stream holds no owner.
const aegis = @import("aegis");
const std = @import("std");
pub const Connecting = struct { result: anyerror!*std.Io.net.Stream };
