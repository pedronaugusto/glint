// Z026 twin: null is returned as an error
pub fn get(o: ?u8) error{Missing}!u8 {
    return o orelse return error.Missing;
}
