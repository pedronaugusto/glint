// matrix: `&p.*` of a pointer into the caller's memory
pub fn f(into: *u32) *u32 {
    into.* += 1;
    const p = into;
    return &p.*;
}
