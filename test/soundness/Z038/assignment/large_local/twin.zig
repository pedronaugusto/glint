// Z038 twin: the same done the way the rule leaves
pub fn first() u8 {
    var buf: [4096]u8 = undefined;
    buf[0] = 1;
    return buf[0];
}
