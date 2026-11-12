// P007: a function of the program's own, held at file scope.
fn foo() void {}
const held: *const fn () void = &foo;
pub fn call() void {
    held();
}
