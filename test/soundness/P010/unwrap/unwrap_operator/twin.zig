// P010 twin: the same done the way the rule leaves
pub fn get(o: ?u8) u8 {
    return o orelse 0;
}
