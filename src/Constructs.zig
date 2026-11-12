//! Every way Zig moves a value, named once: the rows of the soundness matrix
//! (test/soundness/<rule>/<row>/), each case placed in the row of how it moves the value its
//! rule judges.
/// How a construct moves a value, one row of the matrix.
pub const Row = enum {
    /// A store: `x = v`, a variable's initial value, a compound assignment's write.
    assignment,
    /// `a, b = t`: several places written from one value.
    destructure,
    /// A payload bound by `if`, `while`, `for` or a switch prong, by value or `|*p|`.
    capture,
    /// `@field(x, name)`: a part named by a computed name.
    field,
    /// A place and what aliases it: `&x`, `p.*`, a field or element, a slice, a name.
    address,
    /// A value handed to a function or returned from one, a parameter bound.
    call,
    /// `defer` and `errdefer`: code that runs at the scope's exits.
    deferred,
    /// A value carried by a jump: `break :label v`, `continue`, a block's result, `return`.
    jump,
    /// `inline for`, `inline while`, an `inline` prong: a body unrolled per value.
    inline_loop,
    /// Code evaluated by the compiler: `comptime`, `@TypeOf`, `@sizeOf`, a comptime parameter.
    compile_time,
    /// A value computed from others by an operator: arithmetic, bits, comparisons, math.
    operator,
    /// A value converted to another type: `@as`, `@intCast`, `@ptrCast`, `@bitCast`.
    conversion,
    /// A payload out of an optional or error union: `try`, `orelse`, `catch`, `.?`.
    unwrap,
    /// Values put into an aggregate: struct, array, union and vector literals, `++`.
    aggregate,
    /// A value moved through memory by a builtin: `@memcpy`, `@memset`, atomics.
    memory,
    /// A value chosen by a branch: `if` and `switch` as expressions.
    branch,
    /// Moves no value: a type, a declaration, a literal, a check, debug information.
    none,
};
