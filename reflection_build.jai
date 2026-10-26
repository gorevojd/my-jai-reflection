// Import this file in the build metaprogram, then call build_file instead of Compiler.add_build_file.
#scope_file

#import "Basic";
#import "Compiler";

#scope_export

// TODO: Study what is going on here

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
                if !node.defined_type || !has_note(node.notes, "ReflectStruct") || already_seen(*seen, node.defined_type) {
                    continue;
                }
                assert(!catalog_finished, "Reflection: marked struct appeared after the catalog was baked.");
                // Compiler-owned pointers are used only by #run in this same compiler process.
                // The target workspace converts its own Type_Info to relocatable Type values before baking.
                source := sprint(STRUCT_REGISTRATION, cast(u64)node.defined_type);
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
                if !node.external_type || !has_note(node.notes, "ReflectEnum") || already_seen(*seen, node.external_type) {
                    continue;
                }
                assert(!catalog_finished, "Reflection: marked enum appeared after the catalog was baked.");
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
#run {
    R :: #import "MyReflection";
    R.register_reflected_struct(cast(*Type_Info_Struct)%);
}
END_REGISTRATION

ENUM_REGISTRATION :: #string END_REGISTRATION
#run {
    R :: #import "MyReflection";
    C :: #import "Compiler";
    R.register_reflected_enum(cast(*C.Code_Enum)%);
}
END_REGISTRATION

has_note :: (notes: []*Code_Note, text: string) -> bool {
    for note: notes {
        if note.text == text {
            return true;
        }
    }
    return false;
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
