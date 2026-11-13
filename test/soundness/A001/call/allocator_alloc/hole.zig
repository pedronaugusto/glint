// A001: std.mem.bytesAsSlice makes governed cells out of bytes the caller hands it.
const std = @import("std");
const aegis = @import("aegis");
const State = enum(u8) { idle, busy };
const A = aegis.Atomic(State);
pub fn f(bytes: []align(4) u8) []A {
    return std.mem.bytesAsSlice(A, bytes);
}
