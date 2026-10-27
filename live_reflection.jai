// Live views borrow object storage and share generated operations. They never own the inspected object.
#scope_file

#import "Basic";
LiveCompiler :: #import "Compiler";
LiveTables :: #import "Hash_Table";
LiveCountedTables :: #import "Hash_Table"(true);

#scope_export

Reflection_Access :: enum_flags u32 {
    Read :: 0x1;
    Write :: 0x2;
    Resize :: 0x4;
    Insert :: 0x8;
    Remove :: 0x10;
    Invoke :: 0x20;
}

// Plain rejects assignments containing borrowed/owning resources. Borrowed explicitly permits shallow copies.
Assignment_Policy :: enum {
    Plain;
    Borrowed;
    Custom;
}

Reflection_Options :: struct {
    access: Reflection_Access = .Read | .Write;
    assignment: Assignment_Policy;
    assign: (destination: Any, source: Any) -> bool;
    properties: []Property_Binding;
    methods: []Method_Binding;
}

// info retains exact type identity; kind describes the underlying type of a distinct variant.
Type_Metadata :: struct {
    info: *Type_Info;
    kind: Type_Info_Tag;
    struct_meta: *Struct_Metadata;
    enum_meta: *Enum_Metadata;
    array_meta: Array_Metadata;
    is_table: bool;
}

Property_Binding :: struct {
    owner_type: Type;
    value_type: Type;
    name: string;
    read: (owner: *void, destination: *void);
    write: (owner: *void, source: *void) -> bool;
    collections: []Live_Collection;
}

Method_Binding :: struct {
    owner_type: Type;
    procedure_type: Type;
    name: string;
    invoke: (owner: *void, arguments: []Any, results: []Any) -> bool;
}

// Bindings and their names are borrowed by views. Build once and keep their storage alive with the views.
make_property :: ($Owner: Type,
                  $Value: Type,
                  name: string,
                  $getter: (*Owner) -> Value,
                  $setter: (*Owner, Value) -> bool = null) -> Property_Binding
{
    assert(name.count > 0);
    result := Property_Binding.{owner_type = Owner,
                               value_type = Value,
                               name = name,
                               collections = live_collections(Value)};
    #if getter {
        result.read = Live_Property_Ops(Owner, Value, getter, setter).read;
    }
    else {
        #assert false "A reflected property requires a getter.";
    }
    #if setter {
        result.write = Live_Property_Ops(Owner, Value, getter, setter).write;
    }
    return result;
}

make_method :: ($Owner: Type, name: string, $method: $P) -> Method_Binding {
    valid :: #run live_method_valid(type_info(Owner), type_info(P));
    #assert valid "Reflected methods require a runtime procedure with *Owner first.";
    assert(name.count > 0);
    return .{owner_type = Owner, procedure_type = P, name = name, invoke = Live_Method_Ops(Owner, P, method).invoke};
}

get_method_count :: (view: Reflection) -> int {
    if !can_read(view) {
        return 0;
    }
    result: int;
    for binding: view.options.methods {
        if cast(*Type_Info)binding.owner_type == view.root.type {
            result += 1;
        }
    }
    return result;
}

get_method :: (view: Reflection, name: string) -> *Method_Binding {
    if !can_read(view) {
        return null;
    }
    for *binding: view.options.methods {
        if cast(*Type_Info)binding.owner_type == view.root.type && binding.name == name {
            return binding;
        }
    }
    return null;
}

invoke :: (view: Reflection, name: string, arguments: []Any = .[], results: []Any = .[]) -> bool {
    if !is_valid(view) || view.property || !(view.options.access & .Invoke) {
        return false;
    }
    // Invocation permission is independent of whether value reads are exposed.
    for binding: view.options.methods {
        if cast(*Type_Info)binding.owner_type == view.root.type && binding.name == name {
            return binding.invoke(view.root.value_pointer, arguments, results);
        }
    }
    return false;
}

value_reference :: (object: *$T) -> Any {
    result: Any;
    result.type = type_info(T);
    result.value_pointer = object;
    return result;
}

type_metadata :: (value_type: Type) -> Type_Metadata {
    return type_metadata(cast(*Type_Info)value_type);
}

type_metadata :: (info: *Type_Info) -> Type_Metadata {
    result := Type_Metadata.{info = info};
    if !info {
        return result;
    }
    base := live_base_type(info);
    result.kind = base.type;
    if base.type == .STRUCT {
        result.struct_meta = find_struct(base);
        result.is_table = live_table_kind(base) != .None;
    }
    else if base.type == .ENUM {
        result.enum_meta = find_enum(base);
    }
    else if base.type == .ARRAY {
        array := cast(*Type_Info_Array)base;
        result.array_meta = .{element_type = live_type(array.element_type),
                             array_type = array.array_type,
                             fixed_count = array.array_count,
                             element_size = array.element_type.runtime_size};
    }
    return result;
}

create :: (object: *$T, options: Reflection_Options = .{}) -> Reflection {
    validate_live_bindings(options);
    return .{root = value_reference(object), options = options, collections = live_collections(T)};
}

is_valid :: (view: Reflection) -> bool {
    return view.root.type != null && (view.root.value_pointer != null || (view.property != null && view.property_owner != null));
}

get_type :: (view: Reflection) -> *Type_Info {
    return view.root.type;
}

can_read :: (view: Reflection) -> bool {
    return is_valid(view) && (view.options.access & .Read) != 0;
}

can_write :: (view: Reflection) -> bool {
    if !is_valid(view) || !(view.options.access & .Write) {
        return false;
    }
    if view.property {
        return view.property.write != null;
    }
    return live_assignment_allowed(view.root.type, view.options);
}

// Direct values borrow object storage. Computed values use temporary storage until its next reset.
// Treat returned Any storage as read-only; use set_value to honor permissions and ownership policy.
get_value :: (view: Reflection) -> Any {
    result: Any;
    if !can_read(view) {
        return result;
    }
    if !view.property {
        return view.root;
    }
    result.type = view.root.type;
    size := ifx result.type.runtime_size > 0 then result.type.runtime_size else 1;
    result.value_pointer = alloc(size,, temporary_allocator);
    view.property.read(view.property_owner, result.value_pointer);
    return result;
}

get_value :: (view: Reflection, $T: Type) -> (value: T, success: bool) {
    result: T;
    success := read_value(view, *result);
    return result, success;
}

// The destination supplies the static type, so callers need not repeat a Type argument.
read_value :: (view: Reflection, destination: *$T) -> bool {
    return read_value_into(view, value_reference(destination));
}

read_value_into :: (view: Reflection, destination: Any) -> bool {
    if !can_read(view) || !destination.value_pointer || view.root.type != destination.type {
        return false;
    }
    if view.property {
        view.property.read(view.property_owner, destination.value_pointer);
    }
    else {
        return live_copy_value(destination.value_pointer, view.root.value_pointer, destination.type.runtime_size);
    }
    return true;
}

set_value :: (view: Reflection, value: $T) -> bool {
    return set_value(view, value_reference(*value));
}

set_value :: (view: Reflection, value: Any) -> bool {
    if (!is_valid(view) || !(view.options.access & .Write) || !value.value_pointer ||
        value.type != view.root.type) {
        return false;
    }
    if view.property {
        if !view.property.write {
            return false;
        }
        return view.property.write(view.property_owner, value.value_pointer);
    }
    if !live_assignment_allowed(value.type, view.options) {
        return false;
    }
    if view.options.assignment == .Custom {
        return view.options.assign(view.root, value);
    }
    return live_copy_value(view.root.value_pointer, value.value_pointer, value.type.runtime_size);
}

get_capabilities :: (view: Reflection) -> Reflection_Access {
    result: Reflection_Access;
    if can_read(view) {
        result |= .Read;
    }
    if can_write(view) {
        result |= .Write;
    }
    if !is_valid(view) || view.property {
        return result;
    }
    if view.options.access & .Invoke {
        for binding: view.options.methods {
            if cast(*Type_Info)binding.owner_type == view.root.type {
                result |= .Invoke;
                break;
            }
        }
    }
    operations := live_collection(view);
    if !operations || !live_collection_assignment_allowed(operations, view.options) {
        return result;
    }
    if operations.resize {
        result |= view.options.access & .Resize;
    }
    if operations.insert || operations.insert_at {
        result |= view.options.access & .Insert;
    }
    if operations.erase || operations.remove_at {
        result |= view.options.access & .Remove;
    }
    return result;
}

// Permissions can be narrowed on a borrowed view; granting capabilities requires the owner's create call.
with_access :: (view: Reflection, access: Reflection_Access) -> Reflection {
    result := view;
    result.options.access &= access;
    return result;
}

get_property :: (view: Reflection, name: string) -> Reflection {
    source := live_navigation_source(view);
    if !can_read(source) {
        return .{};
    }
    for *binding: source.options.properties {
        if cast(*Type_Info)binding.owner_type == source.root.type && binding.name == name {
            result := source;
            result.entries = .[];
            result.root.type = cast(*Type_Info)binding.value_type;
            result.root.value_pointer = null;
            result.property = binding;
            result.property_owner = source.root.value_pointer;
            result.field_meta = null;
            result.collections = binding.collections;
            return result;
        }
    }
    metadata := type_metadata(source.root.type);
    if !metadata.struct_meta || metadata.is_table {
        return .{};
    }
    for *field: metadata.struct_meta.fields {
        if field.name == name {
            result := live_child(source, cast(*Type_Info)field.member_type, cast(*u8)source.root.value_pointer + field.offset);
            result.field_meta = field;
            return result;
        }
    }
    return .{};
}

get_property_count :: (view: Reflection) -> int {
    source := live_navigation_source(view);
    if !can_read(source) {
        return 0;
    }
    result: int;
    metadata := type_metadata(source.root.type);
    if metadata.struct_meta && !metadata.is_table {
        for field: metadata.struct_meta.fields {
            if !live_property_binding(source, field.name) {
                result += 1;
            }
        }
    }
    for binding: source.options.properties {
        if cast(*Type_Info)binding.owner_type == source.root.type {
            result += 1;
        }
    }
    return result;
}

get_property_name :: (view: Reflection, index: int) -> string {
    source := live_navigation_source(view);
    if !can_read(source) || index < 0 {
        return "";
    }
    metadata := type_metadata(source.root.type);
    if metadata.struct_meta && !metadata.is_table {
        for field: metadata.struct_meta.fields {
            if live_property_binding(source, field.name) {
                continue;
            }
            if index == 0 {
                return field.name;
            }
            index -= 1;
        }
    }
    for binding: source.options.properties {
        if cast(*Type_Info)binding.owner_type != source.root.type {
            continue;
        }
        if index == 0 {
            return binding.name;
        }
        index -= 1;
    }
    return "";
}

get_count :: (view: Reflection) -> int {
    source := live_navigation_source(view);
    if !can_read(source) {
        return 0;
    }
    operations := live_collection(source);
    if operations {
        return operations.count(source.root.value_pointer);
    }
    return get_property_count(source);
}

get_element :: (view: Reflection, index: int) -> Reflection {
    source := live_navigation_source(view);
    operations := live_collection(source);
    if !can_read(source) || !operations || index < 0 || index >= operations.count(source.root.value_pointer) {
        return .{};
    }
    value := operations.at(source.root.value_pointer, index);
    return live_child(source, value.type, value.value_pointer);
}

// A table key and an iteration ordinal use distinct API names, including for integer keys.
get_entry :: (view: Reflection, key: $K) -> Reflection {
    return get_entry(view, value_reference(*key));
}

get_entry :: (view: Reflection, key: Any) -> Reflection {
    source := live_navigation_source(view);
    operations := live_collection(source);
    if (!can_read(source) || !operations || !operations.find || !key.value_pointer ||
        key.type != cast(*Type_Info)operations.key_type) {
        return .{};
    }
    value := operations.find(source.root.value_pointer, key);
    return live_child(source, value.type, value.value_pointer);
}

get_key :: (view: Reflection, ordinal: int) -> Reflection {
    source := live_navigation_source(view);
    operations := live_collection(source);
    if (!can_read(source) || !operations || !operations.key_at || ordinal < 0 ||
        ordinal >= operations.count(source.root.value_pointer)) {
        return .{};
    }
    key := operations.key_at(source.root.value_pointer, ordinal);
    result := live_child(source, key.type, key.value_pointer);
    result.options.access &= .Read;
    return result;
}

resize :: (view: Reflection, count: int) -> bool {
    operations := live_collection(view);
    if (!is_valid(view) || !(view.options.access & .Resize) || !operations || !operations.resize || count < 0 ||
        !live_count_fits(operations, count) || !live_collection_assignment_allowed(operations, view.options)) {
        return false;
    }
    return operations.resize(view.root.value_pointer, count);
}

insert_element :: (view: Reflection, index: int, value: $T) -> bool {
    return insert_element(view, index, value_reference(*value));
}

insert_element :: (view: Reflection, index: int, value: Any) -> bool {
    operations := live_collection(view);
    if (!is_valid(view) || !(view.options.access & .Insert) || !operations || !operations.insert_at ||
        !value.value_pointer || value.type != cast(*Type_Info)operations.element_type || index < 0 ||
        index > operations.count(view.root.value_pointer) ||
        !live_count_fits(operations, operations.count(view.root.value_pointer) + 1) ||
        !live_collection_assignment_allowed(operations, view.options)) {
        return false;
    }
    return operations.insert_at(view.root.value_pointer, index, value);
}

remove_element :: (view: Reflection, index: int) -> bool {
    operations := live_collection(view);
    if (!is_valid(view) || !(view.options.access & .Remove) || !operations || !operations.remove_at || index < 0 ||
        index >= operations.count(view.root.value_pointer) || !live_collection_assignment_allowed(operations, view.options)) {
        return false;
    }
    return operations.remove_at(view.root.value_pointer, index);
}

insert_entry :: (view: Reflection, key: $K, value: $V) -> bool {
    return insert_entry(view, value_reference(*key), value_reference(*value));
}

insert_entry :: (view: Reflection, key: Any, value: Any) -> bool {
    operations := live_collection(view);
    if (!is_valid(view) || !(view.options.access & .Insert) || !operations || !operations.insert || !key.value_pointer ||
        !value.value_pointer || key.type != cast(*Type_Info)operations.key_type ||
        value.type != cast(*Type_Info)operations.element_type || !live_collection_assignment_allowed(operations, view.options)) {
        return false;
    }
    return operations.insert(view.root.value_pointer, key, value);
}

remove_entry :: (view: Reflection, key: $K) -> bool {
    return remove_entry(view, value_reference(*key));
}

remove_entry :: (view: Reflection, key: Any) -> bool {
    operations := live_collection(view);
    if (!is_valid(view) || !(view.options.access & .Remove) || !operations || !operations.erase || !key.value_pointer ||
        key.type != cast(*Type_Info)operations.key_type || !live_collection_assignment_allowed(operations, view.options)) {
        return false;
    }
    return operations.erase(view.root.value_pointer, key);
}

#scope_module

Live_Collection :: struct {
    container_type: Type;
    element_type: Type;
    key_type: Type;
    valid: (*void) -> bool;
    count: (*void) -> int;
    at: (*void, int) -> Any;
    key_at: (*void, int) -> Any;
    find: (*void, Any) -> Any;
    resize: (*void, int) -> bool;
    insert_at: (*void, int, Any) -> bool;
    remove_at: (*void, int) -> bool;
    insert: (*void, Any, Any) -> bool;
    erase: (*void, Any) -> bool;
}

#scope_file

Live_Table_Kind :: enum {
    None;
    Standard;
    Counted;
}

live_table_kind :: (info: *Type_Info) -> Live_Table_Kind {
    if info.type != .STRUCT {
        return .None;
    }
    source := (cast(*Type_Info_Struct)info).polymorph_source_struct;
    if source == type_info(LiveTables.Table(int, int)).polymorph_source_struct {
        return .Standard;
    }
    if source == type_info(LiveCountedTables.Table(int, int)).polymorph_source_struct {
        return .Counted;
    }
    return .None;
}

live_type :: (info: *Type_Info) -> Type {
    return (cast(*Type)*info).*;
}

live_base_type :: (info: *Type_Info) -> *Type_Info {
    while info.type == .VARIANT {
        info = (cast(*Type_Info_Variant)info).variant_of;
    }
    return info;
}

LIVE_MAX_STORAGE_BYTES :: 0x7fffffffffffffff;

live_count_fits :: (operations: *Live_Collection, count: int) -> bool {
    size := (cast(*Type_Info)operations.element_type).runtime_size;
    return count >= 0 && (size == 0 || (size > 0 && count <= LIVE_MAX_STORAGE_BYTES / size));
}

live_copy_value :: (destination: *void, source: *void, size: int) -> bool {
    destination_address := cast(u64)destination;
    source_address := cast(u64)source;
    if destination_address == source_address {
        return true;
    }
    distance := ifx destination_address > source_address then destination_address - source_address else source_address - destination_address;
    if size < 0 || distance < cast(u64)size {
        return false;
    }
    memcpy(destination, source, size);
    return true;
}

live_plain_value :: (info: *Type_Info) -> bool {
    info = live_base_type(info);
    if (info.type == .INTEGER || info.type == .FLOAT || info.type == .BOOL || info.type == .ENUM ||
        info.type == .POINTER || info.type == .TYPE || info.type == .PROCEDURE) {
        return info.runtime_size >= 0;
    }
    if info.type == .ARRAY {
        array := cast(*Type_Info_Array)info;
        return array.array_type == .FIXED && live_plain_value(array.element_type);
    }
    if info.type == .STRUCT {
        structure := cast(*Type_Info_Struct)info;
        if structure.textual_flags & .UNION {
            return false;
        }
        for member: structure.members {
            if !(member.flags & .CONSTANT) && !live_plain_value(member.type) {
                return false;
            }
        }
        return true;
    }
    return false;
}

live_assignment_allowed :: (info: *Type_Info, options: Reflection_Options) -> bool {
    if options.assignment == .Borrowed {
        return info.runtime_size >= 0;
    }
    if options.assignment == .Custom {
        return options.assign != null;
    }
    return live_plain_value(info);
}

live_collection_assignment_allowed :: (operations: *Live_Collection, options: Reflection_Options) -> bool {
    if options.assignment == .Custom {
        return false;
    }
    if !live_assignment_allowed(cast(*Type_Info)operations.element_type, options) {
        return false;
    }
    return !operations.find || live_assignment_allowed(cast(*Type_Info)operations.key_type, options);
}

live_collection :: (view: Reflection) -> *Live_Collection {
    if !is_valid(view) || view.property {
        return null;
    }
    base := live_base_type(view.root.type);
    for *operations: view.collections {
        if cast(*Type_Info)operations.container_type == base {
            if !operations.valid(view.root.value_pointer) {
                return null;
            }
            return operations;
        }
    }
    return null;
}

live_child :: (source: Reflection, info: *Type_Info, pointer: *void) -> Reflection {
    result := source;
    result.root = Any.{type = info, value_pointer = pointer};
    result.entries = .[];
    result.field_meta = null;
    result.property = null;
    result.property_owner = null;
    return result;
}

live_navigation_source :: (view: Reflection) -> Reflection {
    if !view.property {
        return view;
    }
    value := get_value(view);
    result := live_child(view, value.type, value.value_pointer);
    result.options.access &= .Read;
    return result;
}

live_collection_types :: (root: *Type_Info) -> []Type #compile_time {
    pending: [..]*Type_Info;
    seen: [..]*Type_Info;
    result: [..]Type;
    array_add(*pending, root);
    cursor: int;
    while cursor < pending.count {
        info := live_base_type(pending[cursor]);
        cursor += 1;
        duplicate: bool;
        for seen {
            if it == info {
                duplicate = true;
                break;
            }
        }
        if duplicate {
            continue;
        }
        array_add(*seen, info);
        if info.type == .ARRAY {
            array_add(*result, LiveCompiler.get_type(info));
            array_add(*pending, (cast(*Type_Info_Array)info).element_type);
        }
        else if is_standard_table(info) || is_counted_table(info) {
            array_add(*result, LiveCompiler.get_type(info));
            metadata := collect_table_metadata(cast(*Type_Info_Struct)info);
            array_add(*pending, cast(*Type_Info)metadata.value_type);
        }
        else if info.type == .STRUCT {
            metadata := collect_struct(cast(*Type_Info_Struct)info);
            for field: metadata.fields {
                array_add(*pending, cast(*Type_Info)field.member_type);
            }
        }
    }
    array_free(pending);
    array_free(seen);
    return result;
}

live_collections :: ($T: Type) -> []Live_Collection {
    types :: #run live_collection_types(type_info(T));
    #insert -> string {
        builder: String_Builder;
        defer free_buffers(*builder);
        append(*builder, "result :: Live_Collection.[");
        for types {
            if it_index > 0 {
                append(*builder, ",");
            }
            print_to_builder(*builder, "#run Live_Collection_Ops(types[%]).describe()", it_index);
        }
        append(*builder, "];\nreturn result;\n");
        return builder_to_string(*builder);
    }
}

Live_Collection_Ops :: struct (T: Type) {
    IS_TABLE :: #run is_standard_table(type_info(T)) || is_counted_table(type_info(T));
    IS_COUNTED :: #run is_counted_table(type_info(T));
    #if IS_TABLE {
        E :: T.Value_Type;
        K :: T.Key_Type;
    }
    else {
        E :: #run LiveCompiler.get_type(type_info(T).element_type);
        RESIZABLE :: #run type_info(T).array_type == .RESIZABLE;
    }

    describe :: () -> Live_Collection {
        result := Live_Collection.{container_type = T, element_type = E, valid = valid, count = count, at = at};
        #if IS_TABLE {
            result.key_type = K;
            result.key_at = key_at;
            result.find = find;
            result.insert = insert;
            result.erase = erase;
        }
        else #if RESIZABLE {
            result.resize = resize;
            result.insert_at = insert_at;
            result.remove_at = remove_at;
        }
        return result;
    }

    valid :: (raw: *void) -> bool {
        source := cast(*T)raw;
        #if IS_TABLE {
            return (source.count >= 0 && source.allocated >= 0 && source.count <= source.slots_filled &&
                    source.slots_filled <= source.allocated && source.entries.count == source.allocated &&
                    (source.allocated == 0 || source.entries.data != null));
        }
        else {
            #if #run type_info(T).array_type == .FIXED {
                return true;
            }
            else {
                if source.count < 0 || (source.count > 0 && size_of(E) > 0 && !source.data) {
                    return false;
                }
                #if RESIZABLE {
                    return source.count <= source.allocated;
                }
                else {
                    return true;
                }
            }
        }
    }

    count :: (raw: *void) -> int {
        source := cast(*T)raw;
        #if IS_TABLE {
            return source.count;
        }
        else {
            #if #run type_info(T).array_type == .FIXED {
                return type_info(T).array_count;
            }
            else {
                return source.count;
            }
        }
    }

    at :: (raw: *void, index: int) -> Any {
        source := cast(*T)raw;
        #if IS_TABLE {
            for *entry: source.entries {
                if entry.hash < LiveTables.FIRST_VALID_HASH {
                    continue;
                }
                if index == 0 {
                    return value_reference(*entry.value);
                }
                index -= 1;
            }
            return Any.{};
        }
        else {
            return value_reference(*source.*[index]);
        }
    }

    #if IS_TABLE {
        key_at :: (raw: *void, index: int) -> Any {
            source := cast(*T)raw;
            for *entry: source.entries {
                if entry.hash < LiveTables.FIRST_VALID_HASH {
                    continue;
                }
                if index == 0 {
                    return value_reference(*entry.key);
                }
                index -= 1;
            }
            return Any.{};
        }

        find :: (raw: *void, key: Any) -> Any {
            source := cast(*T)raw;
            #if IS_COUNTED {
                pointer := LiveCountedTables.table_find_pointer(source, (cast(*K)key.value_pointer).*);
            }
            else {
                pointer := LiveTables.table_find_pointer(source, (cast(*K)key.value_pointer).*);
            }
            return value_reference(pointer);
        }

        insert :: (raw: *void, key: Any, value: Any) -> bool {
            source := cast(*T)raw;
            copied_key := (cast(*K)key.value_pointer).*;
            copied_value := (cast(*E)value.value_pointer).*;
            #if IS_COUNTED {
                if LiveCountedTables.table_contains(source, copied_key) {
                    return false;
                }
                LiveCountedTables.table_add(source, copied_key, copied_value);
            }
            else {
                if LiveTables.table_contains(source, copied_key) {
                    return false;
                }
                LiveTables.table_add(source, copied_key, copied_value);
            }
            return true;
        }

        erase :: (raw: *void, key: Any) -> bool {
            source := cast(*T)raw;
            #if IS_COUNTED {
                removed, _ := LiveCountedTables.table_remove(source, (cast(*K)key.value_pointer).*);
            }
            else {
                removed, _ := LiveTables.table_remove(source, (cast(*K)key.value_pointer).*);
            }
            return removed;
        }
    }
    else #if RESIZABLE {
        resize :: (raw: *void, count: int) -> bool {
            array_resize(cast(*T)raw, count);
            return true;
        }

        insert_at :: (raw: *void, index: int, value: Any) -> bool {
            copied_value := (cast(*E)value.value_pointer).*;
            array_insert_at(cast(*T)raw, copied_value, index);
            return true;
        }

        remove_at :: (raw: *void, index: int) -> bool {
            array_ordered_remove_by_index(cast(*[]E)raw, index);
            return true;
        }
    }
}

live_property_binding :: (view: Reflection, name: string) -> *Property_Binding {
    for *binding: view.options.properties {
        if cast(*Type_Info)binding.owner_type == view.root.type && binding.name == name {
            return binding;
        }
    }
    return null;
}

validate_live_bindings :: (options: Reflection_Options) {
    for binding, index: options.properties {
        assert(binding.read != null && binding.name.count > 0, "Reflection property needs a name and getter.");
        for previous: 0..index - 1 {
            other := options.properties[previous];
            assert(binding.owner_type != other.owner_type || binding.name != other.name, "Duplicate reflected property '%'.", binding.name);
        }
    }
    for binding, index: options.methods {
        assert(binding.invoke != null && binding.name.count > 0, "Reflection method needs a name and implementation.");
        for previous: 0..index - 1 {
            other := options.methods[previous];
            assert(binding.owner_type != other.owner_type || binding.name != other.name, "Duplicate reflected method '%'.", binding.name);
        }
    }
}

Live_Property_Ops :: struct (Owner: Type, Value: Type, getter: (*Owner) -> Value, setter: (*Owner, Value) -> bool) {
    read :: (raw: *void, destination: *void) {
        value := getter(cast(*Owner)raw);
        memcpy(destination, *value, size_of(Value));
    }

    write :: (raw: *void, source: *void) -> bool {
        #if setter {
            return setter(cast(*Owner)raw, (cast(*Value)source).*);
        }
        else {
            return false;
        }
    }
}

live_method_valid :: (owner: *Type_Info, info: *Type_Info) -> bool #compile_time {
    if info.type != .PROCEDURE {
        return false;
    }
    procedure := cast(*Type_Info_Procedure)info;
    if (procedure.argument_types.count == 0 || procedure.procedure_flags & .IS_POLYMORPHIC ||
        procedure.procedure_flags & .IS_COMPILE_TIME_ONLY) {
        return false;
    }
    first := procedure.argument_types[0];
    return first.type == .POINTER && (cast(*Type_Info_Pointer)first).pointer_to == owner;
}

live_method_arguments :: (info: *Type_Info_Procedure) -> []Type #compile_time {
    result: [..]Type;
    for argument, index: info.argument_types {
        if index > 0 {
            array_add(*result, LiveCompiler.get_type(argument));
        }
    }
    return result;
}

live_method_results :: (info: *Type_Info_Procedure) -> []Type #compile_time {
    result: [..]Type;
    for value: info.return_types {
        array_add(*result, LiveCompiler.get_type(value));
    }
    return result;
}

Live_Method_Ops :: struct (Owner: Type, P: Type, method: P) {
    arguments_types :: #run live_method_arguments(type_info(P));
    results_types :: #run live_method_results(type_info(P));

    invoke :: (owner: *void, arguments: []Any, results: []Any) -> bool {
        if arguments.count != arguments_types.count || results.count != results_types.count {
            return false;
        }
        for argument, index: arguments {
            if !argument.value_pointer || argument.type != cast(*Type_Info)arguments_types[index] {
                return false;
            }
        }
        for result, index: results {
            if !result.value_pointer || result.type != cast(*Type_Info)results_types[index] {
                return false;
            }
        }
        #insert -> string {
            builder: String_Builder;
            defer free_buffers(*builder);
            for arguments_types {
                print_to_builder(*builder, "argument_% := (cast(*arguments_types[%])arguments[%].value_pointer).*;\n",
                                 it_index, it_index, it_index);
            }
            for results_types {
                if it_index > 0 {
                    append(*builder, ", ");
                }
                print_to_builder(*builder, "result_%", it_index);
            }
            if results_types.count > 0 {
                append(*builder, " := ");
            }
            append(*builder, "method(cast(*Owner)owner");
            for arguments_types {
                print_to_builder(*builder, ", argument_%", it_index);
            }
            append(*builder, ");\n");
            for results_types {
                print_to_builder(*builder, "memcpy(results[%].value_pointer, *result_%, size_of(results_types[%]));\n",
                                 it_index, it_index, it_index);
            }
            append(*builder, "return true;\n");
            return builder_to_string(*builder);
        }
    }
}
