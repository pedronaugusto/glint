// A007: a std lock outside a seam: aegis's guarded types are the answer.
const aegis = @import("aegis");
const std = @import("std");
pub fn make() std.Io.Mutex {
    return .init;
}
