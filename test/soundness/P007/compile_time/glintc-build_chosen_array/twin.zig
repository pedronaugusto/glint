// P007: a capture over a slice of a field whose type a build chooses, an array or `void`: the
// slice is compiled only where it is the array, and its element's fields are read (aegis's
// Order, review b9).
const builtin = @import("builtin");
const diagnostics = builtin.mode == .Debug;
const Held = struct { owner: *const anyopaque, rank: usize };
pub const Context = struct {
    stack: if (diagnostics) [32]Held else void = if (diagnostics) undefined else {},
    used: if (diagnostics) usize else void = if (diagnostics) 0 else {},
    pub fn check(self: *const Context, owner: *const anyopaque, rank: usize) bool {
        if (diagnostics) {
            for (self.stack[0..self.used]) |held| {
                if (held.owner == owner) return true;
                if (held.rank > rank) return true;
            }
        }
        return false;
    }
};
