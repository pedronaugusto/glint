// P011 twin: the same done the way the rule leaves
pub fn first() u8 {
    var buf: [4]u8 = @splat(0);
    buf[0] = 1;
    return buf[0];
}
