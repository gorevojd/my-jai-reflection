# MyReflection

Jai type metadata is collected and baked during compilation. Live reflection binds
that shared data and generated operations to an existing object. Build through
`ReflectionBuild.build_file` from `reflection_build.jai`, as in the project's build
metaprogram. No per-object registration or metadata construction is required.

## Values and types

```jai
R :: #import "MyReflection";

number: float = 1.25;
view := R.create(*number);

value := R.get_value(view);                // Any: type_info(float), storage pointing at number
current, success := R.get_value(view, float);

inferred: float;
success = R.read_value(view, *inferred);    // The destination supplies the static type
changed := R.set_value(view, cast(float)2.5);
```

The reflected type is `float`, and the object address is stored separately in the
view. Roots, struct fields and collection elements use the same value semantics.
Primitive values, strings, enums and pointer values have no built-in children.
Pointer values are leaves: reflection does not follow an object graph implicitly.

`get_value(view)` discovers the type from the view and returns an `Any`. The caller
can inspect `value.type`; Jai cannot choose a static return type from runtime data.
An invalid or unreadable view returns an empty `Any` (`type == null`). Direct
values borrow the inspected storage. Computed values use temporary storage until
the next temporary-storage reset. Treat this storage as read-only.

`get_value(view, T)` returns `(T, bool)` and requires exact type identity. There
are no implicit numeric conversions. `read_value(view, *destination)` infers T
from the destination. `read_value_into(view, destination_any)` accepts an explicit
typed storage reference. These reads allocate no memory, including for computed
properties; string/container results copy descriptors and retain their original
storage lifetimes. Use `value_reference(*variable)` to construct an `Any` that
refers to a caller-owned input/output buffer.

`is_valid` checks that a view has a type and an object or computed-property binding.
A null object is invalid. A type absent from the metadata catalog can still have
a valid opaque view with zero exposed fields.

`type_metadata(T)` and `type_metadata(type_info(T))` return `Type_Metadata` for
every native type. `info` preserves exact identity; `kind` unwraps distinct type
variants. Optional struct/enum descriptors, array shape and table classification
supplement the native information. No primitive-type hash catalog is required.

`find_struct` and `find_enum` retain their specialized APIs. Constant-Type
`find_reflection(T)` returns their specialized pointers for structs/enums and
`Type_Metadata` for other types. Runtime `find_reflection(info)` returns a
`Metadata_Reference`: `Struct`, `Enum` or `Value`, with `type_meta` populated.
Only null descriptors return `None`.

## Properties and collections

```jai
object := R.create(*settings);
volume := R.get_property(object, "volume");

element := R.get_element(array_view, 2);
entry := R.get_entry(table_view, key);
```

- `get_property`, `get_property_count` and `get_property_name(view, index)` expose
  the existing baked field selection and explicitly bound computed properties.
  Names are case-sensitive. Constants remain available through `constant_value`.
  Serialization continues using `serialized_fields`; inspection uses `fields`.
- `get_count` returns a collection's logical element count or a struct's property
  count. Fixed arrays, views and resizable arrays all support `get_element`.
- Standard and collision-counting Jai `Hash_Table` instances support `get_entry`
  by key. Their actual hash/comparison functions are used, including custom
  functions. Keys retain the existing reflection restriction to strings, integers,
  enums, floats, booleans and their distinct variants.
- Tables also support `get_element` by iteration ordinal and `get_key` by the
  same ordinal. Key views are read-only. Ordinals are unordered and unstable;
  each ordinal lookup scans occupied storage. Prefer hash lookup for known keys.
- Missing properties/keys and out-of-range indices return invalid views. Looking
  up a missing key never inserts an entry. Malformed collection headers are
  rejected before element access or mutation.

Collection adapters are generated once per concrete type reachable through the
root's fields and collection values. Computed properties carry adapters for their
return types too. Child views inherit the root's binding definitions and access
restrictions. Views do not allocate for ordinary creation, lookup or navigation.

## Permissions and ownership

`Reflection_Options.access` defaults to `Read | Write`. Additional named flags
are `Resize`, `Insert`, `Remove` and `Invoke`. `get_capabilities(view)` reports
effective operations; fixed arrays and slices never report resize or insertion.
`with_access` can narrow an existing view's permissions and cannot elevate them.
Flags are API policy, not a security boundary against code using raw pointers.

```jai
view := R.create(*items, .{access = .Read | .Write | .Resize | .Insert | .Remove});
R.resize(view, 4);
R.insert_element(view, 0, value);
R.remove_element(view, 1);

R.insert_entry(table_view, key, value);
R.remove_entry(table_view, key);
```

Insertion rejects duplicate table keys. Resizing and insertion initialize new
array elements using Jai defaults. Removing an array element preserves order.
Negative sizes, storage-size overflow, wrong types and unavailable capabilities
return false before mutation. Reacquire element views after mutations.

`Assignment_Policy` explicitly defines value ownership:

- `Plain` is the default. Assignment and collection mutation accept plain values
  and aggregates containing only plain values. Strings, runtime array descriptors,
  tables, unions and aggregates containing resources are rejected. The check
  includes native fields omitted from reflection.
- `Borrowed` permits shallow descriptor copies. The caller owns their referenced
  storage and its lifetime. Container mutation releases no element/key resources;
  the native container still owns its backing allocation. No deep copy is implied.
- `Custom` calls `options.assign(destination_any, source_any)` for direct value
  writes. The callback owns copying, releasing and failure behavior. Structural
  collection mutation is unavailable under this policy; use an owner-controlled
  method when resource destruction or allocation needs domain-specific rules.

Computed setters implement their own value and ownership policy. `Invoke` grants
permission to run explicitly bound code, which may mutate the owner even without
the `Write` flag. Use only `Read` for a view that must expose no mutating operations.

ConfigManager-owned tables use ordinary read/write views with no structural
mutation flags. Resource assignments require an owner-supplied setter or callback;
reflection does not maintain ConfigManager's string pools or publish transactions.

All views borrow their object. Move, destruction, successful config reload/save,
array reallocation and table rehash can invalidate them. Keep keys/indices for
persistent UI selections and acquire the current view each time. Existing
`Table_Key_Reference` helpers remain available. Failed config reloads preserve
the current storage and its views.

## Computed properties and methods

```jai
properties := R.Property_Binding.[R.make_property(Settings, float, "volume", get_volume, set_volume)];
methods := R.Method_Binding.[R.make_method(Settings, "reset", reset_settings)];
view := R.create(*settings, .{properties = properties, methods = methods, access = .Read | .Write | .Invoke});
```

`make_property(Owner, Value, name, getter, setter = null)` checks the getter's
`(*Owner) -> Value` signature and the optional setter's `(*Owner, Value) -> bool`
signature. Omitting the setter creates a read-only property. A setter can reject a
value by returning false. Explicit bindings take precedence over a native field
with the same name. Duplicate explicit names for the same owner are rejected.
Bindings and names are borrowed; keep them alive as long as their views.

Navigation inside a computed aggregate materializes a temporary snapshot and
exposes read-only descendants. To modify it, assign the complete computed property
through its setter. This avoids bypassing setters by modifying a temporary child.

`make_method(Owner, name, procedure)` generates a typed invocation wrapper. The
procedure must have a concrete, fixed signature callable at runtime, with `*Owner` as its first
argument. Methods are explicitly bound; a procedure constant is not automatically
exposed for invocation. `get_method` and `get_method_count` inspect bindings.

`invoke(view, name, arguments: []Any, results: []Any) -> bool` requires `Invoke`
permission. Arguments exclude the implicit owner pointer. Results are references
to caller-owned output buffers. Argument/result counts, exact types and nonnull
storage are checked before the method runs. Zero and multiple return values are
supported. Inputs are copied before invocation; outputs are copied from the
procedure's typed results. Ownership follows the procedure's ordinary contract.

## Existing collectors and checks

`capture_reflection(*object, options)` preserves the baked breadth-first `entries`
array alongside the new live view. Existing `collect`, `children`, `parent`,
`reflection_value`, array/table accessors and serialization helpers remain available.

Run `Tests/check_live_reflection.ps1` for live-view behavior and invalid-binding
fixtures, and `Tests/check_reflection_metadata.ps1` for metadata validation.
