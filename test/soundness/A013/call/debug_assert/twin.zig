// A013: aegis's invariant keeps the contract in every build.
const aegis = @import("aegis");
pub fn f(n: u32) u32 {
    aegis.assert.invariant(n > 0, "a positive count");
    return n - 1;
}
