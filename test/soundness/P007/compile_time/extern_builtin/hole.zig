// P007: @extern at file scope binds a symbol Zig does not check (review 8, M1).
const foo = @extern(*const fn () callconv(.c) void, .{ .name = "foo" });
pub fn call() void {
    foo();
}
