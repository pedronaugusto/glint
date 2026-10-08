# glint

Work in progress: a std-only Zig code model and standalone linter. G0/G1 are under construction; family integration and new safety rules have not landed.

## Install

Requires Zig 0.17.0. A fetchable library and standalone CLI are being built.

## Usage

The public interface is under construction.

## Design

Sources → std AST and AstGen/ZIR → scopes and references → module facts → selected rules → diagnostics and CLI. Runtime dependencies: std only. No verifier is pursued.

## Scope

Code-level checks belong here. Architecture and path policy belong to gantry; preflight orchestrates builds and family configuration. No new safety default follows from a compatibility port.

## Built with

Zig std; preflight for build/CI; shakedown for tests only.

## Testing

`zig build check`, `zig build lint`, and targeted `zig build test -Dtest-filter=...`. `zig build plan -- --tier merge --output <file>` generates CI through preflight. `zig build bench` runs the repository's own benchmarks in ReleaseFast.

## Licence

MIT. See LICENSE.
