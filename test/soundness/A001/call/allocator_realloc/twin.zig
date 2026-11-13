// A001: Allocator.realloc reads the old cells as bytes only to move them; what it returns is
// cells again, never their bytes.
const std = @import("std");
const aegis = @import("aegis");
const State = enum(u8) { idle, busy };
const A = aegis.Atomic(State);
pub fn f(gpa: std.mem.Allocator, cells: []A, n: usize) ![]A {
    return gpa.realloc(cells, n);
}
