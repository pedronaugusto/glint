// A015: a stream held by value in an error union (review 8, M7, m14).
const aegis = @import("aegis");
const std = @import("std");
pub const Connecting = struct { result: anyerror!std.Io.net.Stream };
