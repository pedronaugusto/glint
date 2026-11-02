// A019 aggregate: one field of a struct is never written before the struct is read whole
const P = struct { a: u32, b: u32 };
pub fn make(c: bool) P {
    var p: P = undefined;
    p.a = 1;
    if (c) p.b = 2;
    return p;
}
