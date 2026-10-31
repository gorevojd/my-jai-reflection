// Import this file in the build metaprogram, then call build_file instead of Compiler.add_build_file.
#scope_file

#import "Basic";
#import "Compiler";

#scope_export

// Drain all type registrations before baking the shared catalog and its immutable lookup indexes.

build_file :: (path: string, workspace: Workspace) {
    compiler_begin_intercept(workspace);
    add_build_file(path, workspace);
    reflection_import: *Message_Import;
    seen: [..]*Type_Info;
    registrations_added: bool;
    catalog_finished: bool;
    while true {
        message := compiler_wait_for_message();
        if message.kind == .IMPORT {
            imported := cast(*Message_Import)message;
            if imported.module_name == "MyReflection" {
                reflection_import = imported;
            }
        }
        else if message.kind == .TYPECHECKED {
            checked := cast(*Message_Typechecked)message;
            for item: checked.structs {
                node := item.expression;
                if !node.defined_type || already_seen(*seen, node.defined_type) {
                    continue;
                }
                assert(!catalog_finished, "Reflection: struct '%' appeared after the catalog was baked.", node.defined_type.name);
                // Compiler-owned pointers are used only by #run in this same compiler process.
                // The target workspace converts its own Type_Info to relocatable Type values before baking.
                source := sprint(STRUCT_REGISTRATION, cast(u64)node.defined_type, is_generated_context(node));
                add_build_string(source, workspace);
                registrations_added = true;
            }
            enumerations: [..]*Code_Enum;
            for item: checked.all {
                if item.expression.kind == .ENUM {
                    array_add(*enumerations, cast(*Code_Enum)item.expression);
                }
                for expression: item.subexpressions {
                    if expression.kind == .ENUM {
                        array_add(*enumerations, cast(*Code_Enum)expression);
                    }
                }
            }
            for node: enumerations {
                if !node.external_type || already_seen(*seen, node.external_type) {
                    continue;
                }
                assert(!catalog_finished, "Reflection: enum '%' appeared after the catalog was baked.", node.external_type.name);
                source := sprint(ENUM_REGISTRATION, cast(u64)node);
                add_build_string(source, workspace);
                registrations_added = true;
            }
            array_free(enumerations);
        }
        else if message.kind == .PHASE {
            phase := cast(*Message_Phase)message;
            if phase.phase != .TYPECHECKED_ALL_WE_CAN {
                continue;
            }
            if registrations_added {
                // Wait for all injected registrations to execute before freezing their arrays.
                registrations_added = false;
                add_build_string("#run {}", workspace);
            }
            else if reflection_import && !catalog_finished {
                add_build_string("#scope_module\nreflected_catalog :: #run finish_catalog();", workspace, reflection_import);
                catalog_finished = true;
            }
        }
        else if message.kind == .COMPLETE {
            break;
        }
    }
    compiler_end_intercept(workspace);
    array_free(seen);
}

#scope_file

STRUCT_REGISTRATION :: #string END_REGISTRATION
#scope_file
R :: #import "MyReflection";
C :: #import "Compiler";
INFO_ADDRESS :: %;
GENERATED_CONTEXT :: %;
#if #run R.has_custom_serialization_methods(cast(*Type_Info_Struct)INFO_ADDRESS) {
    Registered_Type :: #run C.get_type(cast(*Type_Info_Struct)INFO_ADDRESS);
    #run R.register_reflected_struct(type_info(Registered_Type), GENERATED_CONTEXT,
                                    R.Custom_Serialization(Registered_Type).encode,
                                    R.Custom_Serialization(Registered_Type).decode);
}
else {
    #run R.register_reflected_struct(cast(*Type_Info_Struct)INFO_ADDRESS, GENERATED_CONTEXT);
}
END_REGISTRATION

ENUM_REGISTRATION :: #string END_REGISTRATION
#run {
    R :: #import "MyReflection";
    C :: #import "Compiler";
    R.register_reflected_enum(cast(*C.Code_Enum)%);
}
END_REGISTRATION

is_generated_context :: (node: *Code_Struct) -> bool {
    if (!node.enclosing_load || !node.enclosing_load.enclosing_import ||
        node.enclosing_load.enclosing_import.module_type != .RUNTIME_SUPPORT) {
        return false;
    }
    PREFIX :: "Context";
    name := node.defined_type.name;
    if name.count <= PREFIX.count {
        return false;
    }
    for character, index: PREFIX {
        if name[index] != character {
            return false;
        }
    }
    for index: PREFIX.count..name.count - 1 {
        if name[index] < #char "0" || name[index] > #char "9" {
            return false;
        }
    }
    return true;
}

already_seen :: (seen: *[..]*Type_Info, info: *Type_Info) -> bool {
    for seen.* {
        if it == info {
            return true;
        }
    }
    array_add(seen, info);
    return false;
}
