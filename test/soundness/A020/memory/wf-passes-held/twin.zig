// warp-fast: input decides when the loop ends early, but it runs no more
// passes than the slots it was given hold (Proof.passes, as A009 reads it),
// as warp's zstd/parallel queue.
const std = @import("std");
const Slot = struct { last: bool };
pub fn queue(io: std.Io, r: *std.Io.Reader, slots: []Slot) !usize {
    _ = io;
    var count: usize = 0;
    var last = false;
    while (count < slots.len and !last) : (count += 1) {
        slots[count].last = (try r.takeByte()) == 0;
        last = slots[count].last;
    }
    return count;
}
