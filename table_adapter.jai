#scope_file
#import "Basic";
#import "Hash_Table";
CountedTables :: #import "Hash_Table"(true);

#scope_export

// Generic table operations, independent of the editor's primitive-key restrictions.
Table_Adapter :: struct {
    key_type: Type;
    value_type: Type;
    entry_type: Type;
    entry_size: s64;
    key_offset: s64;
    value_offset: s64;
    hash_offset: s64;
    first_valid_hash: u32;
    load_factor: s64;
    minimum_slots: s64;
    count: #type (data: *u8) -> s64;
    empty: #type (data: *u8) -> bool;
    next: #type (data: *u8, cursor: *s64) -> *u8, *u8;
    access: #type (data: *u8) -> Table_Storage_Access;
    // Reserve room for count additional entries; keep existing entries intact.
    reserve: #type (data: *u8, count: s64);
    find: #type (data: *u8, key: *u8) -> *u8;
    // Native insertion semantics: duplicate keys are permitted, and key/value storage is copied shallowly.
    insert: #type (data: *u8, key: *u8, value: *u8) -> *u8;
    reset: #type (data: *u8);
}

// Borrowed mutable fields. Direct edits must preserve the native table's indexing invariants
// before calling find/insert. Reset frees only entry storage, never resources inside keys/values.
Table_Storage_Access :: struct {
    count: *s64;
    allocated: *s64;
    slots_filled: *s64;
    entries: *Array_View_64;
    allocator: *Allocator;
}

#scope_module

has_table_adapter :: (info: *Type_Info) -> bool #compile_time {
    if info.type != .STRUCT || (cast(*Type_Info_Struct)info).parameters.count != 0 {
        return false;
    }
    return is_standard_table(info) || is_counted_table(info);
}

Typed_Table_Adapter :: struct (T: Type) {
    metadata :: () -> Table_Adapter #compile_time {
        result: Table_Adapter;
        result.key_type = T.Key_Type;
        result.value_type = T.Value_Type;
        result.entry_type = T.Entry;
        result.entry_size = size_of(T.Entry);
        result.key_offset = find_member(type_info(T.Entry), "key").offset_in_bytes;
        result.value_offset = find_member(type_info(T.Entry), "value").offset_in_bytes;
        result.hash_offset = find_member(type_info(T.Entry), "hash").offset_in_bytes;
        result.first_valid_hash = FIRST_VALID_HASH;
        result.load_factor = T.LOAD_FACTOR_PERCENT;
        result.minimum_slots = T.SIZE_MIN;
        result.count = count;
        result.empty = empty;
        result.next = next;
        result.access = access;
        result.reserve = reserve;
        result.find = find;
        result.insert = insert;
        result.reset = reset;
        return result;
    }

    count :: (data: *u8) -> s64 {
        return (cast(*T)data).count;
    }

    empty :: (data: *u8) -> bool {
        table := cast(*T)data;
        return (table.count == 0 &&
                table.allocated == 0 &&
                table.slots_filled == 0 &&
                table.entries.count == 0 &&
                table.entries.data == null);
    }

    next :: (data: *u8, cursor: *s64) -> *u8, *u8 {
        table := cast(*T)data;
        while cursor.* < table.entries.count {
            entry := *table.entries[cursor.*];
            cursor.* += 1;
            if entry.hash >= FIRST_VALID_HASH {
                return cast(*u8)*entry.key, cast(*u8)*entry.value;
            }
        }
        return null, null;
    }

    access :: (data: *u8) -> Table_Storage_Access {
        table := cast(*T)data;
        result: Table_Storage_Access;
        result.count = *table.count;
        result.allocated = *table.allocated;
        result.slots_filled = *table.slots_filled;
        result.entries = cast(*Array_View_64)*table.entries;
        result.allocator = *table.allocator;
        return result;
    }

    reserve :: (data: *u8, count: s64) {
        table := cast(*T)data;
        #if #run is_counted_table(type_info(T)) {
            CountedTables.table_ensure_space(table, count);
        }
        else {
            table_ensure_space(table, count);
        }
    }

    find :: (data: *u8, key: *u8) -> *u8 {
        table := cast(*T)data;
        typed_key := (cast(*T.Key_Type)key).*;
        #if #run is_counted_table(type_info(T)) {
            return cast(*u8)CountedTables.table_find_pointer(table, typed_key);
        }
        else {
            return cast(*u8)table_find_pointer(table, typed_key);
        }
    }

    insert :: (data: *u8, key: *u8, value: *u8) -> *u8 {
        table := cast(*T)data;
        typed_key := (cast(*T.Key_Type)key).*;
        typed_value := (cast(*T.Value_Type)value).*;
        #if #run is_counted_table(type_info(T)) {
            return cast(*u8)CountedTables.table_add(table, typed_key, typed_value);
        }
        else {
            return cast(*u8)table_add(table, typed_key, typed_value);
        }
    }

    reset :: (data: *u8) {
        table := cast(*T)data;
        #if #run is_counted_table(type_info(T)) {
            CountedTables.table_reset(table);
        }
        else {
            table_reset(table);
        }
    }
}
