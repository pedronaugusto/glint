// P007: a pointer made from an integer at file scope, dereferenced at run time (review 8, M2).
const reg: *volatile u32 = @ptrFromInt(0x4000_0000);
pub fn poke() void {
    reg.* = 1;
}
