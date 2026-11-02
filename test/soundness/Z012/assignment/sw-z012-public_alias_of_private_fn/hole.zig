// A public alias of a private function: callers call `make` and get a Hidden they cannot name.
const Hidden = struct { x: u8 };
fn makeHidden() Hidden {
    return .{ .x = 1 };
}
pub const make = makeHidden;
