// X002: a key made by its own generator into a local, held plainly.
const module = @import("module");

pub fn f() [32]u8 {
    const key = module.Key.generate(1);
    return key.bytes;
}
