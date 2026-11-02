// A019 unwrap: `orelse` goes on with a default where the write happens only on the payload's path
pub fn get(o: ?u32) u32 {
    var x: u32 = undefined;
    if (o) |v| x = v;
    return x;
}
