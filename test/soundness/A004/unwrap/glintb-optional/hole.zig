// glint-b: A004 unwrap (optional): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(maybe: ?Index) u16 {
    return maybe.?.raw() + 1;
}
