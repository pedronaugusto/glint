// review 7 pre: a01/s04_list.zig
const aegis = @import("aegis");
// The secret's backing field read through @field over a literal list of names.
pub fn f(s: *const aegis.Secret(u64)) u64 {
    var out: u64 = 0;
    inline for (.{"material"}) |name| out = @field(s, name);
    return out;
}
