// matrix A007: the same inline for over aegis's Atomic.
const aegis = @import("aegis");
const Phase = enum(u32) { idle, busy };
const Wide = enum(u64) { idle, busy };
pub fn claimed() u64 {
    var sum: u64 = 0;
    inline for (.{ aegis.Atomic(Phase), aegis.Atomic(Wide) }) |Cell| {
        var cell: Cell = .init(.idle);
        sum += @backingInt(cell.swap(.busy, .acq_rel));
    }
    return sum;
}
