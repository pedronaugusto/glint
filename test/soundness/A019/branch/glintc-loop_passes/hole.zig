// A019 branch: a loop over a slice of an array, which may be empty, writes in its body only
pub fn slicedArray(k: usize) u32 {
    var x: u32 = undefined;
    const arr: [4]u32 = .{ 1, 2, 3, 4 };
    for (arr[0..k]) |v| x = v;
    return x;
}
