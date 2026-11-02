// A019 unwrap: `orelse return` leaves where there is no payload, so the read follows the write
pub fn get(o: ?u32) u32 {
    var x: u32 = undefined;
    x = o orelse return 0;
    return x;
}
