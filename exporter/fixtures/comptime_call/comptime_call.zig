fn square(x: u32) u32 {
    return x * x;
}
const nine = square(3);
export fn entry() u32 {
    const four = comptime square(2);
    return four + nine;
}
