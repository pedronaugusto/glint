// A007: aegis an element of tuples joined by ++, its guard made: none.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{aegis};
pub fn make() both[1].BlockingGuarded(u32) {
    return .init(0);
}
