const P = struct { nanoseconds: i96 };
pub fn f(raw: *i96) *P {
    return @fieldParentPtr("nanoseconds", raw);
}
