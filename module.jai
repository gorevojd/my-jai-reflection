// Build with #run collect(type_info(My_Struct)). Returned strings and arrays are baked into the executable.
// Mark structs @ReflectStruct and enums @ReflectEnum. The build hook gathers marked types automatically.
#scope_file

#import "Basic";
Math :: #import "MyMath";
Strings :: #import "string_utils";
Compiler :: #import "Compiler";
Tables :: #import "Hash_Table";
TablesWithCollisions :: #import "Hash_Table"(true);

#scope_export

Numeric_Range :: struct {
    has_min, has_max: bool;
    minimum, maximum: float64;
}

Field_Metadata :: struct {
    name: string;
    offset: int;
    member_type: Type;
    is_serialized: bool;
    display_name: string;
    tooltip: string;
    groups: []string;
    range: Numeric_Range;
}

Struct_Metadata :: struct {
    struct_type: Type;
    name: string;
    is_serialized: bool;
    serialize_fields_by_default: bool = true;
    // Reflected fields include fields whose default serialization is disabled.
    fields: []Field_Metadata;
    // Shares fields when every field is enabled; otherwise this is the prefiltered subset.
    serialized_fields: []Field_Metadata;
}

Table_Metadata :: struct {
    key_type: Type;
    value_type: Type;
    storage: Table_Storage;
}

// Live table rows are leaves. Keys are read-only; values may be edited through their borrowed pointers.
Table_Entry :: struct {
    key: Any;
    value: Any;
}

// Persistent identity without a stored table/slot pointer. String keys own an independent text copy.
// Do not copy a live owning reference; destroy it once when its UI state is discarded.
Table_Key_Reference :: struct (K: Type) {
    key: K;
    owned_text: string;
    allocator: Allocator;
    valid: bool;
}

Array_Metadata :: struct {
    element_type: Type;
    array_type: Type_Info_Array.Array_Type;
    fixed_count: int = -1;
    element_size: int;
}

// A view into existing array storage. No element data is copied or owned by this view.
Array_View :: struct {
    element_type: Type;
    count: int;
    data: *u8;
    element_size: int;
}

// Breadth-first tree: index 0 is the root with an empty path and no parent. Offsets are root-relative.
Entry :: struct {
    path: string;
    offset: int;
    member_type: Type;
    parent_index: int = -1;
    first_child_index: int;
    child_count: int;
    struct_meta: Struct_Metadata;
    field_meta: Field_Metadata;
    table_meta: Table_Metadata;
    array_meta: Array_Metadata;
}

Enum_Field_Metadata :: struct {
    name: string;
    value: s64;
    display_name: string;
}

Enum_Metadata :: struct {
    enum_type: Type;
    fields: []Enum_Field_Metadata;
}

// These catalogs are baked by reflection_build.jai; no application type list is required.
reflected_structs :: () -> []Struct_Metadata {
    return reflected_catalog.structures;
}

reflected_enums :: () -> []Enum_Metadata {
    return reflected_catalog.enums;
}

find_struct :: (info: *Type_Info) -> *Struct_Metadata {
    for *metadata: reflected_catalog.structures {
        if cast(*Type_Info)metadata.struct_type == info {
            return metadata;
        }
    }
    return null;
}

find_enum :: (enum_type: Type) -> *Enum_Metadata {
    return find_enum(cast(*Type_Info)enum_type);
}

find_enum :: (info: *Type_Info) -> *Enum_Metadata {
    for *metadata: reflected_catalog.enums {
        if cast(*Type_Info)metadata.enum_type == info {
            return metadata;
        }
    }
    return null;
}

// Baked field selection; runtime serializers consume fields without scanning source notes.
collect_struct :: (info: *Type_Info_Struct) -> Struct_Metadata #compile_time {
    result := Struct_Metadata.{struct_type = Compiler.get_type(info), name = info.name};

    for note: info.notes {
        if note == "ReflectStruct" {
            result.is_serialized = true;
        }
    }

    if !result.is_serialized {
        return result;
    }

    SERIALIZATION_DEFAULT_PREFIX :: "SerializeFieldsByDefault=";
    for note: info.notes {
        if note == "SerializeFieldsByDefault" || note == "SerializeFieldsByDefault=true" {
            result.serialize_fields_by_default = true;
        }
        else if note == "SerializeFieldsByDefault=false" {
            result.serialize_fields_by_default = false;
        }
        else if (note.count >= SERIALIZATION_DEFAULT_PREFIX.count &&
                 string.{SERIALIZATION_DEFAULT_PREFIX.count, note.data} == SERIALIZATION_DEFAULT_PREFIX) {
            assert(false, "Metadata %: SerializeFieldsByDefault must be true or false.", info.name);
        }
    }

    fields: [..]Field_Metadata;
    serialized_fields: [..]Field_Metadata;
    for member: info.members {
        if member.flags & .CONSTANT {
            continue;
        }

        excluded: bool;
        enabled := result.serialize_fields_by_default;
        for note: member.notes {
            if note == "NonSerializeField" {
                excluded = true;
            }
            else if note == "SerializeField" {
                enabled = true;
            }
        }

        if excluded {
            continue;
        }

        field := parse_member(member, info.name);
        field.name = member.name;
        field.offset = member.offset_in_bytes;
        field.member_type = Compiler.get_type(member.type);
        field.is_serialized = enabled;
        array_add(*fields, field);

        if enabled {
            array_add(*serialized_fields, field);
        }
    }

    result.fields = fields;
    result.serialized_fields = ifx fields.count == serialized_fields.count then fields else serialized_fields;
    return result;
}

collect_structs :: (roots: ..*Type_Info) -> []Struct_Metadata #compile_time {
    pending: [..]*Type_Info;
    for roots {
        array_add(*pending, it);
    }
    seen: [..]*Type_Info;
    result: [..]Struct_Metadata;
    cursor: int;
    while cursor < pending.count {
        info := pending[cursor];
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
            array_add(*pending, (cast(*Type_Info_Array)info).element_type);
        }
        else if info.type == .STRUCT {
            metadata := collect_struct(cast(*Type_Info_Struct)info);
            array_add(*result, metadata);
            for field: metadata.fields {
                array_add(*pending, cast(*Type_Info)field.member_type);
            }
        }
    }
    return result;
}

struct_fields :: (structures: []Struct_Metadata, info: *Type_Info) -> []Field_Metadata {
    for structure: structures {
        if cast(*Type_Info)structure.struct_type == info && structure.is_serialized {
            return structure.serialized_fields;
        }
    }
    return .[];
}

enum_display_name :: (metadata: Enum_Metadata, name: string) -> string {
    for field: metadata.fields {
        if field.name == name && field.display_name.count > 0 {
            return field.display_name;
        }
    }
    return name;
}

find :: (entries: []Entry, offset: int, info: *Type_Info) -> *Entry {
    for *entry: entries {
        if entry.offset == offset && cast(*Type_Info)entry.member_type == info {
            return entry;
        }
    }
    return null;
}

// Direct children are contiguous; their descendants may live elsewhere in the array.
children :: (entries: []Entry, node_index: int) -> []Entry {
    if node_index < 0 || node_index >= entries.count {
        return .[];
    }

    entry := entries[node_index];
    if entry.child_count == 0 {
        return .[];
    }

    return array_view(entries, entry.first_child_index, entry.child_count);
}

parent :: (entries: []Entry, node_index: int) -> *Entry {
    if node_index < 0 || node_index >= entries.count {
        return null;
    }
    parent_index := entries[node_index].parent_index;
    if parent_index < 0 || parent_index >= entries.count {
        return null;
    }
    return *entries[parent_index];
}

// Reuses caller-owned row storage. Refresh after mutations; pointers must not outlive the table's storage.
table_entries :: (node: *Entry, table: *$T, rows: *[..]Table_Entry) -> bool {
    value: Any;
    value.type = type_info(T);
    value.value_pointer = table;
    return table_entries_from_any(node, value, rows);
}

table_entries_from_any :: (node: *Entry, table: Any, rows: *[..]Table_Entry) -> bool {
    if !node || node.table_meta.storage.entry_size == 0 || table.type != cast(*Type_Info)node.member_type || !table.value_pointer {
        return false;
    }
    storage := node.table_meta.storage;
    data := cast(*u8)table.value_pointer;
    // Array views have the same count/data header regardless of element type; count is the number of slots.
    slots := (cast(*[]u8)(data + storage.entries_offset)).*;
    array_reset(rows);
    for index: 0..slots.count - 1 {
        slot := slots.data + index * storage.entry_size;
        hash := (cast(*u32)(slot + storage.hash_offset)).*;
        if hash < Tables.FIRST_VALID_HASH {
            continue;
        }
        row: Table_Entry;
        row.key.type = cast(*Type_Info)node.table_meta.key_type;
        row.key.value_pointer = slot + storage.key_offset;
        row.value.type = cast(*Type_Info)node.table_meta.value_type;
        row.value.value_pointer = slot + storage.value_offset;
        array_add(rows, row);
    }
    return true;
}

make_table_key_reference :: (key: $K) -> Table_Key_Reference(K) {
    #assert #run is_primitive_key(type_info(K));
    result := Table_Key_Reference(K).{key = key, valid = true};
    #if #run is_string_key(type_info(K)) {
        result.allocator = context.allocator;
        result.owned_text = copy_string((cast(*string)*key).*);
        memcpy(*result.key, *result.owned_text, size_of(K));
    }
    return result;
}

destroy_table_key_reference :: (reference: *Table_Key_Reference($K)) {
    if !reference {
        return;
    }
    #if #run is_string_key(type_info(K)) {
        if reference.allocator.proc {
            push_allocator(reference.allocator);
            free(reference.owned_text);
        }
    }
    reference.* = .{};
}

// Resolve against the current table on every access. The result is short-lived; retain the key reference instead.
resolve_table_key :: (table: *$T, reference: *Table_Key_Reference(table.Key_Type)) -> *table.Value_Type {
    #assert #run is_standard_table(type_info(T)) || is_counted_table(type_info(T));
    if !table || !reference || !reference.valid {
        return null;
    }
    #if #run is_counted_table(type_info(T)) {
        return TablesWithCollisions.table_find_pointer(table, reference.key);
    } else {
        return Tables.table_find_pointer(table, reference.key);
    }
}

array_elements :: (node: *Entry, array: *$T) -> (view: Array_View, success: bool) {
    value: Any;
    value.type = type_info(T);
    value.value_pointer = array;
    result, accepted := array_elements_from_any(node, value);
    return result, accepted;
}

array_elements_from_any :: (node: *Entry, array: Any) -> (view: Array_View, success: bool) {
    if !node || !cast(*Type_Info)node.array_meta.element_type || array.type != cast(*Type_Info)node.member_type || !array.value_pointer {
        return .{}, false;
    }
    metadata := node.array_meta;
    result := Array_View.{element_type = metadata.element_type, element_size = metadata.element_size};
    if metadata.array_type == .FIXED {
        result.count = metadata.fixed_count;
        result.data = cast(*u8)array.value_pointer;
    } else {
        // Views and resizable arrays share the leading count/data header. Read count, never capacity.
        source := (cast(*[]u8)array.value_pointer).*;
        result.count = source.count;
        result.data = source.data;
    }
    if result.count < 0 || (result.count > 0 && result.element_size > 0 && !result.data) {
        return .{}, false;
    }
    return result, true;
}

// The returned Any points at the original element. An invalid index returns an empty Any (type == null).
array_element :: (view: Array_View, index: int) -> Any {
    result: Any;
    if index < 0 || index >= view.count {
        return result;
    }
    result.type = cast(*Type_Info)view.element_type;
    result.value_pointer = view.data + index * view.element_size;
    return result;
}

// Keep the index in persistent UI state and acquire the current data pointer only when accessing it.
array_element_at :: (node: *Entry, array: *$T, index: int) -> Any {
    view, accepted := array_elements(node, array);
    if !accepted {
        result: Any;
        return result;
    }
    return array_element(view, index);
}

collect :: (info: *Type_Info, leaf_types: []*Type_Info = .[]) -> []Entry #compile_time {
    entries: [..]Entry;
    root := make_entry(info);
    if info.type == .STRUCT && root.table_meta.storage.entry_size == 0 && !root.struct_meta.is_serialized {
        return .[];
    }
    array_add(*entries, root);
    // The growing array is also the queue. Appending a parent's direct children preserves BFS order.
    cursor: int;
    while cursor < entries.count {
        node_index := cursor;
        cursor += 1;
        node := entries[node_index];
        member_info := cast(*Type_Info)node.member_type;
        if member_info.type != .STRUCT || node.table_meta.storage.entry_size > 0 {
            continue;
        }
        if node_index > 0 {
            leaf: bool;
            for leaf_types {
                if it == member_info {
                    leaf = true;
                    break;
                }
            }
            if leaf {
                continue;
            }
        }
        collect_children(*entries, node_index);
    }
    return entries;
}

#scope_module

register_reflected_struct :: (info: *Type_Info_Struct) #compile_time {
    array_add(*pending_catalog.structures, collect_struct(info));
}

register_reflected_enum :: (node: *Compiler.Code_Enum) #compile_time {
    array_add(*pending_catalog.enums, collect_enum_node(node));
}

finish_catalog :: () -> Metadata_Catalog #compile_time {
    return .{structures = pending_catalog.structures, enums = pending_catalog.enums};
}

#scope_file

Metadata_Catalog :: struct {
    structures: []Struct_Metadata;
    enums: []Enum_Metadata;
}

Pending_Catalog :: struct {
    structures: [..]Struct_Metadata;
    enums: [..]Enum_Metadata;
}

pending_catalog: Pending_Catalog;

collect_enum_node :: (enumeration: *Compiler.Code_Enum) -> Enum_Metadata #compile_time {
    enabled: bool;

    for note: enumeration.notes {
        if note.text == "ReflectEnum" {
            enabled = true;
        }
    }

    if !enabled {
        return .{};
    }

    info := enumeration.external_type;
    assert(info != null, "Enum metadata: the build hook requires a typechecked enum declaration.");

    fields: [..]Enum_Field_Metadata;
    for name, index: info.names {
        field := Enum_Field_Metadata.{name = name, value = info.values[index]};
        hidden: bool;
        for member: enumeration.block.members {
            if member.kind != .DECLARATION || member.name != name {
                continue;
            }

            declaration := cast(*Compiler.Code_Declaration)member;
            for note: declaration.notes {
                if note.text == "Hidden" {
                    hidden = true;
                    break;
                }
            }
            if hidden {
                break;
            }
            for note: declaration.notes {
                parsed := parse_note(note.text, info.name, name);
                assert(parsed.kind == .DisplayName, "Enum metadata %.%: only DisplayName is supported; got '%'.", info.name, name, parsed.name);
                assert(field.display_name.count == 0, "Enum metadata %.%: duplicate DisplayName note.", info.name, name);
                field.display_name = parsed.value;
            }

            break;
        }
        if hidden {
            continue;
        }
        array_add(*fields, field);
    }

    return .{enum_type = Compiler.get_type(info), fields = fields};
}

Table_Storage :: struct {
    entries_offset: int;
    entry_size: int;
    hash_offset, key_offset, value_offset: int;
}

is_standard_table :: (info: *Type_Info) -> bool #compile_time {
    if info.type != .STRUCT {
        return false;
    }
    source := (cast(*Type_Info_Struct)info).polymorph_source_struct;
    return source == type_info(Tables.Table(int, int)).polymorph_source_struct;
}

is_counted_table :: (info: *Type_Info) -> bool #compile_time {
    if info.type != .STRUCT {
        return false;
    }
    source := (cast(*Type_Info_Struct)info).polymorph_source_struct;
    return source == type_info(TablesWithCollisions.Table(int, int)).polymorph_source_struct;
}

primitive_key_info :: (info: *Type_Info) -> *Type_Info #compile_time {
    while info.type == .VARIANT {
        info = (cast(*Type_Info_Variant)info).variant_of;
    }
    return info;
}

is_primitive_key :: (info: *Type_Info) -> bool #compile_time {
    info = primitive_key_info(info);
    return (info.type == .STRING || info.type == .INTEGER || info.type == .ENUM ||
            info.type == .FLOAT || info.type == .BOOL);
}

is_string_key :: (info: *Type_Info) -> bool #compile_time {
    return primitive_key_info(info).type == .STRING;
}

make_entry :: (info: *Type_Info) -> Entry #compile_time {
    result := Entry.{member_type = Compiler.get_type(info)};
    if info.type == .ARRAY {
        array := cast(*Type_Info_Array)info;
        result.array_meta = .{element_type = Compiler.get_type(array.element_type),
                         array_type = array.array_type,
                         fixed_count = array.array_count,
                         element_size = array.element_type.runtime_size};
        return result;
    }

    if info.type != .STRUCT {
        return result;
    }

    structure := cast(*Type_Info_Struct)info;
    result.struct_meta = collect_struct(structure);
    if is_standard_table(info) || is_counted_table(info) {
        result.table_meta = collect_table_metadata(structure);
    }
    return result;
}

find_member :: (info: *Type_Info_Struct, name: string) -> *Type_Info_Struct_Member #compile_time {
    for *member: info.members {
        if member.name == name && !(member.flags & .CONSTANT) {
            return member;
        }
    }
    return null;
}

collect_table_metadata :: (info: *Type_Info_Struct) -> Table_Metadata #compile_time {
    entries := find_member(info, "entries");
    assert(entries && entries.type.type == .ARRAY, "Reflection table metadata: missing entries array.");

    array := cast(*Type_Info_Array)entries.type;
    assert(array.array_type == .VIEW && array.element_type.type == .STRUCT, "Reflection table metadata: unsupported entries layout.");

    record := cast(*Type_Info_Struct)array.element_type;
    key := find_member(record, "key");
    value := find_member(record, "value");
    hash := find_member(record, "hash");
    assert(key && value && hash && hash.type == type_info(u32), "Reflection table metadata: unsupported entry layout.");
    assert(is_primitive_key(key.type),
           "Reflection table keys must be primitive (string, integer, enum, float or bool); got %.", Compiler.get_type(key.type));

    return .{key_type = Compiler.get_type(key.type),
             value_type = Compiler.get_type(value.type),
             storage = .{entries_offset = entries.offset_in_bytes,
                         entry_size = record.runtime_size,
                         hash_offset = hash.offset_in_bytes,
                         key_offset = key.offset_in_bytes,
                         value_offset = value.offset_in_bytes}};
}

parse_member :: (member: Type_Info_Struct_Member, owner_name: string = "") -> Field_Metadata {
    result: Field_Metadata;
    seen: [NOTE_KEY_COUNT]bool;
    for note: member.notes {
        // Selection is baked by collect_struct; these markers are not editor labels or ranges.
        if note == "SerializeField" || note == "NonSerializeField" {
            continue;
        }
        parsed := parse_note(note, owner_name, member.name);
        kind := parsed.kind;
        key := parsed.name;
        value := parsed.value;
        assert(!seen[cast(int)kind], "Metadata %.%: duplicate '%' note.", owner_name, member.name, key);
        seen[cast(int)kind] = true;
        if kind == .DisplayName {
            result.display_name = value;
        }
        else if kind == .Tooltip {
            result.tooltip = value;
        }
        else if kind == .Group {
            groups := Strings.decode_groups(value);
            for group: groups {
                assert(group.count > 0, "Metadata %.%: Group '%' contains an empty path component.", owner_name, member.name, value);
                for ch: group {
                    assert(ch >= #char " ", "Metadata %.%: Group '%' contains a control character.", owner_name, member.name, value);
                }
            }
            result.groups = groups;
        } else {
            limit := parse_limit(value, member.type, owner_name, member.name, key);
            if kind == .Min {
                result.range.has_min = true;
                result.range.minimum = limit;
            } else {
                result.range.has_max = true;
                result.range.maximum = limit;
            }
        }
    }
    if result.range.has_min && result.range.has_max {
        assert(result.range.minimum <= result.range.maximum, "Metadata %.%: Min exceeds Max.", owner_name, member.name);
    }
    return result;
}

Note_Key :: enum {
    Unknown;
    DisplayName;
    Tooltip;
    Min;
    Max;
    Group;
}

NOTE_KEY_COUNT :: #run enum_highest_value(Note_Key) + 1;

Parsed_Note :: struct {
    kind: Note_Key;
    name: string;
    value: string;
}

parse_note :: (note: string, owner: string, member: string) -> Parsed_Note {
    separator: int = -1;
    for ch, index: note {
        if ch == #char "=" {
            separator = index;
            break;
        }
    }
    assert(separator > 0, "Metadata %.%: expected Key=Value, got '%'.", owner, member, note);
    key := Strings.trim(string.{separator, note.data});
    value := Strings.trim(string.{note.count - separator - 1, note.data + separator + 1});
    kind: Note_Key = .Unknown;
    if key == "DisplayName" {
        kind = .DisplayName;
    }
    else if key == "Tooltip" {
        kind = .Tooltip;
    }
    else if key == "Min" {
        kind = .Min;
    }
    else if key == "Max" {
        kind = .Max;
    }
    else if key == "Group" {
        kind = .Group;
    }
    assert(kind != .Unknown, "Metadata %.%: unknown key '%' in '%'.", owner, member, key, note);
    assert(value.count > 0, "Metadata %.%: '%' must not be empty.", owner, member, key);
    for ch: value {
        assert(ch != 0, "Metadata %.%: '%' contains a NUL character.", owner, member, key);
    }
    return .{kind, key, value};
}

collect_children :: (entries: *[..]Entry, parent_index: int) #compile_time {
    // Copy before appending: array growth may relocate the parent's storage.
    parent_entry := entries.*[parent_index];
    first_child_index := entries.count;
    for source_field: parent_entry.struct_meta.fields {
        field := source_field;
        path := ifx parent_entry.path.count > 0 then sprint("%.%", parent_entry.path, field.name) else field.name;
        if field.groups.count == 0 {
            field.groups = parent_entry.field_meta.groups;
        }
        node := make_entry(cast(*Type_Info)field.member_type);
        node.path = path;
        node.offset = parent_entry.offset + field.offset;
        node.field_meta = field;
        node.parent_index = parent_index;
        array_add(entries, node);
    }
    child_count := entries.count - first_child_index;
    if child_count > 0 {
        entries.*[parent_index].first_child_index = first_child_index;
    }
    entries.*[parent_index].child_count = child_count;
}

is_digit :: (ch: u8) -> bool {
    return ch >= #char "0" && ch <= #char "9";
}

// Require a complete decimal number, so text, nonfinite spellings and partial parses cannot become limits.
valid_number :: (text: string) -> bool {
    cursor: int;
    if text[cursor] == #char "-" || text[cursor] == #char "+" {
        cursor += 1;
    }
    start := cursor;
    while cursor < text.count && is_digit(text[cursor]) {
        cursor += 1;
    }
    if cursor == start {
        return false;
    }
    if cursor < text.count && text[cursor] == #char "." {
        cursor += 1;
        start = cursor;
        while cursor < text.count && is_digit(text[cursor]) {
            cursor += 1;
        }
        if cursor == start {
            return false;
        }
    }
    if cursor < text.count && (text[cursor] == #char "e" || text[cursor] == #char "E") {
        cursor += 1;
        if cursor < text.count && (text[cursor] == #char "-" || text[cursor] == #char "+") {
            cursor += 1;
        }
        start = cursor;
        while cursor < text.count && is_digit(text[cursor]) {
            cursor += 1;
        }
        if cursor == start {
            return false;
        }
    }
    return cursor == text.count;
}

// Normalize decimal/exponent notation before checking integer bounds, without rounding through float64.
integer_magnitude :: (text: string) -> (magnitude: u64, negative: bool, valid: bool) {
    cursor: int;
    magnitude: u64;
    negative := text[0] == #char "-";
    if negative || text[0] == #char "+" {
        cursor += 1;
    }
    first_digit := cursor;
    digits, fractional_digits, trailing_zeros: int;
    fraction: bool;
    nonzero: bool;
    while cursor < text.count && text[cursor] != #char "e" && text[cursor] != #char "E" {
        ch := text[cursor];
        cursor += 1;
        if ch == #char "." {
            fraction = true;
            continue;
        }
        digits += 1;
        if fraction {
            fractional_digits += 1;
        }
        if ch == #char "0" {
            trailing_zeros += 1;
        } else {
            trailing_zeros = 0;
            nonzero = true;
        }
    }
    if !nonzero {
        return 0, negative, true;
    }
    exponent: int;
    if cursor < text.count {
        cursor += 1;
        exponent_negative := text[cursor] == #char "-";
        if exponent_negative || text[cursor] == #char "+" {
            cursor += 1;
        }
        while cursor < text.count {
            // An exponent beyond the text length cannot restore a nonzero integer to a u64-sized value.
            if exponent > text.count + 64 {
                return 0, negative, false;
            }
            exponent = exponent * 10 + cast(int)(text[cursor] - #char "0");
            cursor += 1;
        }
        if exponent_negative {
            exponent = -exponent;
        }
    }
    shift := exponent - fractional_digits;
    removed := ifx shift < 0 then -shift else 0;
    if removed > trailing_zeros {
        return 0, negative, false;
    }
    remaining := digits - removed;
    cursor = first_digit;
    for index: 0..remaining - 1 {
        if text[cursor] == #char "." {
            cursor += 1;
        }
        digit := cast(u64)(text[cursor] - #char "0");
        cursor += 1;
        if magnitude > (Math.U64_MAX - digit) / 10 {
            return 0, negative, false;
        }
        magnitude = magnitude * 10 + digit;
    }
    while shift > 0 {
        if magnitude > Math.U64_MAX / 10 {
            return 0, negative, false;
        }
        magnitude *= 10;
        shift -= 1;
    }
    return magnitude, negative, true;
}

parse_limit :: (text: string, info: *Type_Info, owner: string, field: string, key: string) -> float64 {
    assert(info.type == .INTEGER || info.type == .FLOAT, "Metadata %.%: % requires a numeric member.", owner, field, key);
    assert(valid_number(text), "Metadata %.%: % '%' must be a complete decimal number.", owner, field, key, text);
    value, success, remainder := string_to_float64(text);
    assert(success && remainder.count == 0 && Math.is_finite(value), "Metadata %.%: % '%' must be finite.", owner, field, key, text);
    if info.type == .FLOAT {
        if info.runtime_size == size_of(float32) {
            assert(Math.is_finite(cast(float32)value), "Metadata %.%: % '%' exceeds float32 range.", owner, field, key, text);
        }
        assert(value != 0.0 || decimal_is_zero(text), "Metadata %.%: % '%' underflows float64.", owner, field, key, text);
        if info.runtime_size == size_of(float32) && value != 0.0 {
            assert(cast(float32)value != 0.0, "Metadata %.%: % '%' underflows float32.", owner, field, key, text);
        }
        return value;
    }
    integer := cast(*Type_Info_Integer)info;
    magnitude, negative, integral := integer_magnitude(text);
    assert(integral, "Metadata %.%: % '%' must be an integer within its member's range.", owner, field, key, text);
    bits := info.runtime_size * 8;
    limit: u64 = Math.U64_MAX;
    if integer.signed {
        limit = cast(u64)1 << (bits - 1);
        if !negative {
            limit -= 1;
        }
    }
    else if bits < 64 {
        limit = (cast(u64)1 << bits) - 1;
    }
    assert((integer.signed || !negative || magnitude == 0) && magnitude <= limit,
           "Metadata %.%: % '%' exceeds its integer member's range.", owner, field, key, text);

    // Numeric_Range uses float64. Reject integer endpoints that cannot be represented exactly in that format.
    significant := magnitude;
    while significant > 0 && (significant & 1) == 0 {
        significant >>= 1;
    }
    assert(significant <= MAX_EXACT_FLOAT64_INTEGER,
           "Metadata %.%: % '%' loses integer precision in float64 metadata.", owner, field, key, text);

    return value;
}

decimal_is_zero :: (text: string) -> bool {
    for ch: text {
        if ch == #char "e" || ch == #char "E" {
            break;
        }
        if ch >= #char "1" && ch <= #char "9" {
            return false;
        }
    }
    return true;
}

MAX_EXACT_FLOAT64_INTEGER :: 0x1F_FFFF_FFFF_FFFF;
