//! `redfish_codegen` — the CSDL/EDMX to Zig generator.
//!
//! The pipeline, in the order the stages run:
//!
//!   1. `csdl` — parse an EDMX document into exactly what it says.
//!   2. `schema_index` — index namespaces across documents, resolve aliases.
//!   3. `compile` — resolve inheritance, apply Redfish annotations, produce
//!      the code model.
//!   4. `optimize` — prune to the surface a profile can reach.
//!   5. `emit` — write a Zig package, then normalize it with `zig fmt`.
//!
//! Modeled on `azure-sdk-for-zig/codegen/cli`; see `doc/architecture.md`,
//! "Emitter conventions". Stages land one at a time through Phase 3.

const std = @import("std");

pub const annotations = @import("annotations.zig");
pub const codemodel = @import("codemodel.zig");
pub const compile = @import("compile.zig");
pub const csdl = @import("csdl.zig");
pub const filter = @import("filter.zig");
pub const identifiers = @import("identifiers.zig");
pub const naming = @import("naming.zig");
pub const permissions = @import("permissions.zig");
pub const schema_index = @import("schema_index.zig");
pub const types = @import("types.zig");

pub const Document = csdl.Document;
pub const Schema = csdl.Schema;
pub const TypeRef = csdl.TypeRef;
pub const SchemaIndex = schema_index.SchemaIndex;
pub const Model = codemodel.Model;

test {
    std.testing.refAllDecls(@This());
    _ = annotations;
    _ = codemodel;
    _ = compile;
    _ = csdl;
    _ = filter;
    _ = identifiers;
    _ = naming;
    _ = permissions;
    _ = schema_index;
    _ = types;
}
