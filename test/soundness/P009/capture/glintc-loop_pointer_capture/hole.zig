// glint-c: A014 capture: a struct local's array is given the frame's address through a loop's pointer capture over it, and the struct is returned
const Views = struct { each: [2][]const u8 = .{ &.{}, &.{} } };
pub fn views() Views {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    var out: Views = .{};
    for (&out.each) |*slot| slot.* = &buf;
    return out;
}
