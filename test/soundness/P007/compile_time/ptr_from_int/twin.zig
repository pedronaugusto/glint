// P007: a pointer to the program's own memory, held at file scope.
var word: u32 = 0;
const reg: *volatile u32 = &word;
pub fn poke() void {
    reg.* = 1;
}
