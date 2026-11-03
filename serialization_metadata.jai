#scope_file
#import "Basic";
#import "MyBasic";
#import "MyBasic/MyName";
Math :: #import "MyMath";

Size_Bake_State :: enum {
    Unvisited;
    Visiting;
    Done;
}

#scope_module

bake_serialization_sizes :: (structures: []Struct_Metadata) #compile_time {
    states: [..]Size_Bake_State;
    array_resize(*states, structures.count);
    defer array_free(states);
    for *metadata: structures {
        calculate_fixed_serialization_size(cast(*Type_Info)metadata.struct_type, structures, states);
    }
}

#scope_file

calculate_fixed_serialization_size :: (info: *Type_Info,
                                      structures: []Struct_Metadata,
                                      states: []Size_Bake_State) -> s64, int #compile_time
{
    MAX_SIZE :: Math.S64_MAX;
    if info.type == .BOOL || info.type == .INTEGER || info.type == .FLOAT || info.type == .ENUM {
        return info.runtime_size, 0;
    }
    if info == type_info(Name) || info == type_info(Binary) || info == type_info(BinaryView) {
        return -1, 0;
    }
    if info.type == .ARRAY {
        array := cast(*Type_Info_Array)info;
        if array.array_type != .FIXED || array.array_count < 0 {
            return -1, 0;
        }
        size, depth := calculate_fixed_serialization_size(array.element_type, structures, states);
        overhead := 2 * size_of(u64);
        if size < 0 || (size > 0 && array.array_count > (MAX_SIZE - overhead) / size) {
            return -1, 0;
        }
        return overhead + array.array_count * size, ifx array.array_count > 0 then depth + 1 else 0;
    }
    if info.type != .STRUCT {
        return -1, 0;
    }
    index: int = -1;
    for metadata, candidate: structures {
        if cast(*Type_Info)metadata.struct_type == info {
            index = candidate;
            break;
        }
    }
    if index < 0 || states[index] == .Visiting {
        return -1, 0;
    }
    metadata := *structures[index];
    if states[index] == .Done {
        return metadata.serialized_size, metadata.serialized_depth;
    }
    states[index] = .Visiting;
    defer states[index] = .Done;
    structure := cast(*Type_Info_Struct)info;
    if (metadata.custom_serialization ||
        metadata.restrict_serialization ||
        metadata.is_hash_table ||
        metadata.is_hash_set ||
        (structure.textual_flags & .UNION) ||
        (structure.textual_flags & .UNION_IS_TAGGED))
    {
        return -1, 0;
    }
    for member: structure.members {
        if member.flags & .OVERLAY {
            return -1, 0;
        }
    }
    payload: s64;
    depth: int;
    for field: metadata.serialized_fields {
        field_size, field_depth := calculate_fixed_serialization_size(cast(*Type_Info)field.member_type, structures, states);
        if field_size < 0 || field_size > MAX_SIZE - size_of(u64) - payload {
            return -1, 0;
        }
        payload += field_size;
        depth = max(depth, field_depth + 1);
    }
    metadata.serialized_payload_size = payload;
    metadata.serialized_size = size_of(u64) + payload;
    metadata.serialized_depth = depth;
    return metadata.serialized_size, depth;
}
