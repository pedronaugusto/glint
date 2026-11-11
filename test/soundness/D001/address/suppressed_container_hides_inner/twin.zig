// twin: the inner function is named by the container's public function
// glint-ignore: D001 -- kept for the port that lands next
const Legacy = struct {
    fn called() u8 {
        return 1;
    }
    pub fn get() u8 {
        return called();
    }
};
pub const one = 1;
