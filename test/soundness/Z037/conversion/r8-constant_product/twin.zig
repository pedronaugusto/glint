// Z037 (review 8, M13): both operands are constants the compiler knows: the product is computed,
// and checked, as it compiles.
const a: u32 = 1000;
const b: u32 = 1000;
pub const product: u64 = a * b;
