// glint-c: A014 capture: a struct local's array is given the caller's memory through a loop's pointer capture over it, and the struct is returned
const Views = struct { each: [2][]const u8 = .{ &.{}, &.{} } };
pub fn views(given: []const u8) Views {
    var out: Views = .{};
    for (&out.each) |*slot| slot.* = given;
    return out;
}
