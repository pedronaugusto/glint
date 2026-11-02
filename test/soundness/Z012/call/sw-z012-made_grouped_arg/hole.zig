// A public type function made with a private type given in parentheses at its declaration.
const std = @import("std");
const Hidden = (struct { x: u8 });
pub fn make() std.ArrayList(Hidden) {
    return .empty;
}
