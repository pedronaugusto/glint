// Z026: orelse unreachable, a panic or undefined behaviour in ReleaseFast where the value is null
pub fn get(o: ?u8) u8 {
    return o orelse unreachable;
}
