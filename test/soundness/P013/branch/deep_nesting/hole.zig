// P013: the reported form
pub fn deep(a: u8) u8 {
    if (a > 0) {
        if (a > 1) {
            if (a > 2) {
                if (a > 3) {
                    if (a > 4) {
                        if (a > 5) return 6;
                    }
                }
            }
        }
    }
    return 0;
}
