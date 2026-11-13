// X002: the key made in place by the answer, its generator handed to it: the owner as the
// answer's argument and the generator as one are the answer, no site (8d).
const module = @import("module");

pub fn f() u8 {
    var owner: module.Owner(module.Key) = undefined;
    owner.make(module.Key.generate, .{1});
    return owner.value.bytes[0];
}
