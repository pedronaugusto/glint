// P007: wrapping sums of vectors, chained: no pointer in it.
pub fn f(sum: [4]@Vector(2, u64)) u64 {
    return @reduce(.Add, sum[0] +% sum[1] +% sum[2] +% sum[3]);
}
