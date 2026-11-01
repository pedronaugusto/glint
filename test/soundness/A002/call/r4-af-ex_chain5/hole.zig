// review 4: af/ex_chain5.zig
const S = @import("aegis").Secret;
pub fn f(s: *S(u32)) *const u32 {
    const v0 = s.expose();
    const v1 = v0;
    const v2 = v1;
    const v3 = v2;
    const v4 = v3;
    const v5 = v4;
    return v5;
}
