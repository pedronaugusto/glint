// D001: the outer container's finding is suppressed; its own dead private function goes unreported
// glint-ignore: D001 -- kept for the port that lands next
const Legacy = struct {
    fn neverCalled() u8 {
        return 1;
    }
};
pub const one = 1;
