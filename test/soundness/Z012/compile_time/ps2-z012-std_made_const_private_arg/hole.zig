const std = @import("std");
const Hidden = struct { x: u8 };
pub const List = std.ArrayList(Hidden);
