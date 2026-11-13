// A001: Allocator.alloc hands back storage for the cells, undefined until each is made by the
// type's own maker: a typed pointer to memory the callee allocates is no reflection (reactor's
// lanes and receiver links).
const std = @import("std");
const aegis = @import("aegis");
const State = enum(u8) { idle, busy };
const A = aegis.Atomic(State);
pub fn f(gpa: std.mem.Allocator, n: usize) ![]A {
    const cells = try gpa.alloc(A, n);
    for (cells) |*cell| cell.* = .init(.idle);
    return cells;
}
