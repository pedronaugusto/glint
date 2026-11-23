// P007: a sum whose left operand is an `if` choosing a call's number or a literal: a number,
// and no pointer moves (cloak's DTLS record limits, review b9).
const Cipher = enum {
    a,
    b,
    pub fn explicitNonceLength12(c: Cipher) usize {
        return if (c == .a) 8 else 0;
    }
    pub fn tagLength(c: Cipher) usize {
        return if (c == .a) 16 else 12;
    }
};
const Epoch = struct { version: enum { dtls12, dtls13 }, cipher: Cipher };
const header12 = 13;
fn overhead13(n: usize) usize {
    return n + 5;
}
pub fn overLimit(keys: *const Epoch, body_len: usize, receive: usize) bool {
    const explicit = if (keys.version == .dtls12) keys.cipher.explicitNonceLength12() else 0;
    return body_len > explicit + keys.cipher.tagLength() + receive;
}
pub fn ack(keys: ?*const Epoch, out: []u8, cid: usize) bool {
    const overhead = if (keys == null) header12 else overhead13(cid);
    return out.len < overhead + 2 + 16;
}
