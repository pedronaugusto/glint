// Z038: the reported form
pub fn first() u8 {
    var buf: [1 << 20]u8 = undefined;
    buf[0] = 1;
    return buf[0];
}
