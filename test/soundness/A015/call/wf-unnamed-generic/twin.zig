// warp-fast: the same choice of holders called for a number, which holds no resource
const A = struct {
    pub fn count(v: u32) u32 {
        return v;
    }
};
const B = struct {
    pub fn count(v: u32) u32 {
        return v + 1;
    }
};
pub fn f(comptime first: bool) u32 {
    return (if (first) A else B).count(1);
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn both() u32 {
    return f(true) + f(false);
}
