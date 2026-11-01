// matrix: the address of the caller's struct's field named by @field, returned
const S = struct { a: u32 = 0, b: u32 = 0 };
pub fn f(s: *S) *u32 {
    s.a = 1;
    return &@field(s, "a");
}
