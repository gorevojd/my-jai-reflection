#scope_file
#import "Basic";
#import "Hash_Table";
Sets :: #import "MyBasic/MyHashSet";
CountedTables :: #import "Hash_Table"(true);

#scope_export

Hash_Collection_Kind :: enum {
    Table;
    Set;
}

// Shared storage/serialization operations. Key pointers are for reading or initializing detached staging entries only.
Hash_Collection_Adapter :: struct {
    kind: Hash_Collection_Kind;
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
    access: #type (data: *u8) -> Hash_Storage_Access;
    // Reserve room for count additional entries; keep existing entries intact.
    reserve: #type (data: *u8, count: s64);
    // Checked allocation for an empty collection; native insertion of count entries will not grow it.
    try_reserve_empty: #type (data: *u8, count: s64) -> bool;
    contains: #type (data: *u8, key: *u8) -> bool;
    // Tables only: borrowed value pointer. Sets leave this callback null.
    find: #type (data: *u8, key: *u8) -> *u8;
    // Shallow native insertion: tables permit duplicates and return the value pointer.
    // Sets ignore value, reject duplicates and return null; query contains before inserting.
    insert: #type (data: *u8, key: *u8, value: *u8) -> *u8;
    reset: #type (data: *u8);
}

// Compatibility name for existing collection-adapter consumers.
Table_Adapter :: Hash_Collection_Adapter;

// Borrowed mutable fields. Direct edits must preserve the native collection's indexing invariants
// before calling find/insert. Reset frees only entry storage, never resources inside keys/values.
Hash_Storage_Access :: struct {
    count: *s64;
    allocated: *s64;
    slots_filled: *s64;
    entries: *Array_View_64;
    allocator: *Allocator;
}

// Compatibility name for existing table storage access.
Table_Storage_Access :: Hash_Storage_Access;

/**
 * @brief Allocates checked storage for an empty HashSet or Hash_Table.Table (including collision counting).
 * @param[in,out] collection Empty collection with no reserved storage; its allocator may be configured.
 * @param[in] count Number of distinct subsequent insertions that must fit without allocating.
 * @return False on invalid arguments, size overflow or allocation failure; the collection remains unchanged on failure.
 * @note Keys/values are not constructed until insertion. Reset/deinit uses the saved allocator as usual.
 */
try_reserve_empty_hash_collection :: (collection: *$T, count: s64) -> bool {
    #assert T.LOAD_FACTOR_PERCENT > 0 && T.LOAD_FACTOR_PERCENT < 100;

    if (count < 0 ||
        collection.count != 0 ||
        collection.allocated != 0 ||
        collection.slots_filled != 0 ||
        collection.entries.count != 0 ||
        collection.entries.data != null)
    {
        return false;
    }

    if count == 0 {
        return true;
    }

    capacity, valid := hash_collection_capacity(count, size_of(T.Entry), T.LOAD_FACTOR_PERCENT, T.SIZE_MIN);
    if !valid {
        return false;
    }

    allocator := collection.allocator;
    if allocator.proc == null {
        allocator = ifx context.allocator.proc != null then context.allocator else context.default_allocator;
    }

    bytes := capacity * size_of(T.Entry);
    entries := cast(*T.Entry)alloc(bytes,, allocator);
    if entries == null {
        return false;
    }

    memset(entries, 0, bytes);
    collection.entries.data = entries;
    collection.entries.count = capacity;
    collection.allocated = capacity;
    collection.allocator = allocator;
    return true;
}

// Compatibility name for existing native-collection callers.
try_reserve_empty_table :: try_reserve_empty_hash_collection;

/**
 * @brief Computes checked power-of-two hash storage capacity, shared by adapters and deserialization budgets.
 * @param[in] count Nonnegative number of entries.
 * @param[in] entry_size Native entry size in bytes.
 * @param[in] load_factor Load percentage strictly between 0 and 100.
 * @param[in] minimum_slots Native minimum slot capacity.
 * @return Slot capacity and validity flag; zero entries need no storage.
 */
hash_collection_capacity :: (count: s64, entry_size: s64, load_factor: s64, minimum_slots: s64) -> s64, bool {
    MAX_SIZE :: 0x7fffffffffffffff;
    if (count < 0 ||
        entry_size <= 0 ||
        load_factor <= 0 ||
        load_factor >= 100 ||
        minimum_slots <= 0 ||
        count > (MAX_SIZE - 99) / 100 - 1)
    {
        return 0, false;
    }
    if count == 0 {
        return 0, true;
    }
    // Leave room below native insertion's >= load-factor threshold.
    slots := max(minimum_slots, ((count + 1) * 100 + 99) / load_factor);
    capacity: s64 = 1;
    while capacity < slots {
        if capacity > MAX_SIZE / 2 {
            return 0, false;
        }
        capacity *= 2;
    }
    if capacity > MAX_SIZE / entry_size || capacity > MAX_SIZE / 100 {
        return 0, false;
    }
    return capacity, true;
}

#scope_module

is_hash_set :: (info: *Type_Info) -> bool {
    if info.type != .STRUCT {
        return false;
    }
    source := (cast(*Type_Info_Struct)info).polymorph_source_struct;
    return source == type_info(Sets.HashSet(int)).polymorph_source_struct;
}

has_hash_collection_adapter :: (info: *Type_Info) -> bool #compile_time {
    if info.type != .STRUCT || (cast(*Type_Info_Struct)info).parameters.count != 0 {
        return false;
    }
    return is_standard_table(info) || is_counted_table(info) || is_hash_set(info);
}

Typed_Hash_Collection_Adapter :: struct (T: Type) {
    IS_SET :: #run is_hash_set(type_info(T));
    #assert Sets.HashSet(int).FIRST_VALID_HASH == FIRST_VALID_HASH;
    metadata :: () -> Hash_Collection_Adapter #compile_time {
        result: Hash_Collection_Adapter;
        result.key_type = T.Key_Type;
        #if IS_SET {
            result.kind = .Set;
        }
        else {
            result.kind = .Table;
            result.value_type = T.Value_Type;
            result.value_offset = find_member(type_info(T.Entry), "value").offset_in_bytes;
        }
        result.entry_type = T.Entry;
        result.entry_size = size_of(T.Entry);
        result.key_offset = find_member(type_info(T.Entry), "key").offset_in_bytes;
        result.hash_offset = find_member(type_info(T.Entry), "hash").offset_in_bytes;
        #if IS_SET {
            result.first_valid_hash = Sets.HashSet(int).FIRST_VALID_HASH;
        }
        else {
            result.first_valid_hash = FIRST_VALID_HASH;
        }
        result.load_factor = T.LOAD_FACTOR_PERCENT;
        result.minimum_slots = T.SIZE_MIN;
        result.count = count;
        result.empty = empty;
        result.next = next;
        result.access = access;
        result.reserve = reserve;
        result.try_reserve_empty = try_reserve_empty;
        result.contains = contains;
        #if !IS_SET {
            result.find = find;
        }
        result.insert = insert;
        result.reset = reset;
        return result;
    }

    count :: (data: *u8) -> s64 {
        return (cast(*T)data).count;
    }

    empty :: (data: *u8) -> bool {
        collection := cast(*T)data;
        return (collection.count == 0 &&
                collection.allocated == 0 &&
                collection.slots_filled == 0 &&
                collection.entries.count == 0 &&
                collection.entries.data == null);
    }

    next :: (data: *u8, cursor: *s64) -> *u8, *u8 {
        collection := cast(*T)data;
        while cursor.* < collection.entries.count {
            entry := *collection.entries[cursor.*];
            cursor.* += 1;
            if entry.hash >= FIRST_VALID_HASH {
                #if IS_SET {
                    return cast(*u8)*entry.key, null;
                }
                else {
                    return cast(*u8)*entry.key, cast(*u8)*entry.value;
                }
            }
        }
        return null, null;
    }

    access :: (data: *u8) -> Hash_Storage_Access {
        collection := cast(*T)data;
        result: Hash_Storage_Access;
        result.count = *collection.count;
        result.allocated = *collection.allocated;
        result.slots_filled = *collection.slots_filled;
        result.entries = cast(*Array_View_64)*collection.entries;
        result.allocator = *collection.allocator;
        return result;
    }

    reserve :: (data: *u8, count: s64) {
        collection := cast(*T)data;
        #if IS_SET {
            Sets.ensure_space(collection, count);
        }
        else #if #run is_counted_table(type_info(T)) {
            CountedTables.table_ensure_space(collection, count);
        }
        else {
            table_ensure_space(collection, count);
        }
    }

    try_reserve_empty :: (data: *u8, count: s64) -> bool {
        return try_reserve_empty_hash_collection(cast(*T)data, count);
    }

    contains :: (data: *u8, key: *u8) -> bool {
        #if IS_SET {
            return Sets.contains((cast(*T)data).*, (cast(*T.Key_Type)key).*);
        }
        else {
            return find(data, key) != null;
        }
    }

    #if !IS_SET {
        find :: (data: *u8, key: *u8) -> *u8 {
            collection := cast(*T)data;
            typed_key := (cast(*T.Key_Type)key).*;
            #if #run is_counted_table(type_info(T)) {
                return cast(*u8)CountedTables.table_find_pointer(collection, typed_key);
            }
            else {
                return cast(*u8)table_find_pointer(collection, typed_key);
            }
        }
    }

    insert :: (data: *u8, key: *u8, value: *u8) -> *u8 {
        collection := cast(*T)data;
        typed_key := (cast(*T.Key_Type)key).*;
        #if IS_SET {
            Sets.add(collection, typed_key);
            return null;
        }
        else {
            typed_value := (cast(*T.Value_Type)value).*;
            #if #run is_counted_table(type_info(T)) {
                return cast(*u8)CountedTables.table_add(collection, typed_key, typed_value);
            }
            else {
                return cast(*u8)table_add(collection, typed_key, typed_value);
            }
        }
    }

    reset :: (data: *u8) {
        collection := cast(*T)data;
        #if IS_SET {
            Sets.reset(collection);
        }
        else #if #run is_counted_table(type_info(T)) {
            CountedTables.table_reset(collection);
        }
        else {
            table_reset(collection);
        }
    }
}
