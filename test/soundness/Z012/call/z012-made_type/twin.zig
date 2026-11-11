// A type function's call in a signature: the rule reads a type written by name, not what a call
// makes, so this is silent by the claim.
const std = @import("std");
const Hidden = struct { x: u8 };
pub fn make() std.ArrayList(Hidden) {
    return .empty;
}
