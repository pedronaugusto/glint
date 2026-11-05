// A record's `kind` kept by hand as a state machine: moved on its own value in one function, set in
// another, switched on, and copied from another record in a third. The copy carries a state chosen
// where that record's was; the move on its own value is still one.
const std = @import("std");
pub const Unit = struct {
    kind: enum { word, string, punctuation },
    text: []const u8,
    pub fn advance(u: *Unit) void {
        u.kind = switch (u.kind) {
            .word => .string,
            .string => .punctuation,
            .punctuation => .word,
        };
    }
    pub fn reset(u: *Unit) void {
        u.kind = .word;
    }
    pub fn like(u: *Unit, other: Unit) void {
        u.kind = other.kind;
    }
};
