// matrix: the address of a local's field named by @field, returned
const S = struct { a: u32 = 0, b: u32 = 0 };
pub fn f() *u32 {
    var s: S = .{};
    s.a = 1;
    return &@field(s, "a");
}
