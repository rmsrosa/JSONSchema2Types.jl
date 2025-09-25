using JSON
using URIs
using Dates

# Mapping of JSON Schema types to Julia types
const TYPE_MAP = Dict(
    "string" => "String",
    "number" => "Float64",
    "integer" => "Int64",
    "boolean" => "Bool"
)

# Cache for loaded schemas to avoid redundant file reads
const SCHEMA_CACHE = Dict{String, Any}()

# Function to load a JSON schema from a file or the cache
function load_schema(filepath::String)::Any
    normalized_path = normpath(filepath)
    if haskey(SCHEMA_CACHE, normalized_path)
        return SCHEMA_CACHE[normalized_path]
    end
    
    if !isfile(normalized_path)
        error("Schema file not found: $(normalized_path)")
    end
    
    schema_content = read(normalized_path, String)
    schema = JSON.parse(schema_content)
    SCHEMA_CACHE[normalized_path] = schema
    println("✅ Loaded schema from: $(normalized_path)")
    return schema
end

"""
    pascal_case(s::AbstractString)

Return a Pascal case version of the string `s`.

Pascal case changes, if necessary, every initial word character to uppercase, removes
every word separator ` `, `-`, `_`, and `.`, and does not change the case of the remaining
characters.
"""
pascal_case(s::AbstractString) = 
    replace(titlecase(s, strict=false), r" |-|_|\." => "")

# Helper function to create docstrings from a schema description and field descriptions
function create_docstring(schema, properties::Dict, struct_name::String, indent::String="")::String
    description = get(schema, "description", "")
    has_field_docs = any(haskey(p, "description") for p in values(properties))
    
    docstring_content = "$(indent)    $(struct_name)\n\n"
    if !isempty(description)
        docstring_content *= description
    end

    if has_field_docs
        field_docs = "\n\nFields:\n"
        for (prop_name, prop_schema) in properties
            field_description = get(prop_schema, "description", "")
            if !isempty(field_description)
                field_docs *= "$(indent)    `$(prop_name)`: $(field_description)\n"
            end
        end
        docstring_content *= field_docs
    end

    if isempty(docstring_content)
        return ""
    end

    docstring = "$(indent)\"\"\"
$(indent)$(docstring_content)
$(indent)\"\"\"
"
    return docstring
end

# Generates the Julia type string from a schema snippet
function generate_type_string(schema, base_path::String, parent_struct_name::String, prop_name::String="")::String
    ref = get(schema, "\$ref", nothing)
    if ref !== nothing
        uri = URI(ref)
        if isempty(uri.path)
            # Local reference
            def_name = split(uri.fragment, "/")[end]
            return pascal_case(def_name)
        else
            # External reference
            ext_path = normpath(joinpath(dirname(base_path), uri.path))
            load_schema(ext_path)
            def_name = split(uri.fragment, "/")[end]
            return pascal_case(def_name)
        end
    end

    if haskey(schema, "enum")
        enum_values = schema["enum"]
        enum_types = unique(typeof.(enum_values))
        julia_type = length(enum_types) == 1 ? enum_types[1] : Union{enum_types...}
        return string(julia_type)
    elseif haskey(schema, "oneOf")
        types = [generate_type_string(s, base_path, parent_struct_name, prop_name * "OneOf" * string(i)) for (i,s) in enumerate(schema["oneOf"])]
        return "Union{" * join(types, ", ") * "}"
    elseif haskey(schema, "anyOf")
        types = [generate_type_string(s, base_path, parent_struct_name, prop_name * "AnyOf" * string(i)) for (i,s) in enumerate(schema["anyOf"])]
        return "Union{" * join(types, ", ") * "}"
    elseif haskey(schema, "not")
        return "Any # The type of this field is constrained by a 'not' keyword and must be validated at runtime."
    end
    
    prop_type = get(schema, "type", "")
    if haskey(TYPE_MAP, prop_type)
        return TYPE_MAP[prop_type]
    elseif prop_type == "object"
        return pascal_case(parent_struct_name * pascal_case(prop_name))
    elseif prop_type == "array"
        items_schema = get(schema, "items", Dict())
        if get(items_schema, "type", "") == "object"
            # Prefer schema title if available, otherwise derive from property name
            item_name = get(items_schema, "title", pascal_case(parent_struct_name * pascal_case(prop_name)))
            items_type_str = pascal_case(item_name)
        else
            items_type_str = generate_type_string(items_schema, base_path, parent_struct_name, prop_name)
        end
        return "Vector{$(items_type_str)}"
    else
        return "Any"
    end
end


# Recursively finds all nested object schemas and their suggested names
function find_all_objects(schema, parent_name::String, base_path::String)
    objects_to_generate = Dict{String, Any}()
    anon_counter = 0
    function traverse(sub_schema, sub_name::String, is_root=false)
        if isa(sub_schema, Dict) && get(sub_schema, "type", "") == "object" && !is_root
            if !haskey(objects_to_generate, sub_name)
                objects_to_generate[sub_name] = sub_schema
            end
        end
        
        properties = get(sub_schema, "properties", Dict())
        if haskey(sub_schema, "allOf")
            for s in sub_schema["allOf"]
                merge!(properties, get(s, "properties", Dict()))
            end
        end

        for (prop_name, prop_schema) in properties
            prop_type = get(prop_schema, "type", "")
            if prop_type == "object"
                nested_struct_name = pascal_case(sub_name * pascal_case(prop_name))
                traverse(prop_schema, nested_struct_name)
            elseif prop_type == "array"
                items_schema = get(prop_schema, "items", Dict())
                if get(items_schema, "type", "") == "object"
                    item_name = get(items_schema, "title", pascal_case(sub_name * pascal_case(prop_name)))
                    nested_struct_name = pascal_case(item_name)
                    traverse(items_schema, nested_struct_name)
                end
            elseif haskey(prop_schema, "oneOf")
                for (i,s) in enumerate(prop_schema["oneOf"])
                    if get(s, "type", "") == "object"
                        obj_name = get(s, "title", pascal_case(prop_name * "OneOf" * string(i)))
                        traverse(s, obj_name)
                    end
                end
            elseif haskey(prop_schema, "anyOf")
                for (i,s) in enumerate(prop_schema["anyOf"])
                    if get(s, "type", "") == "object"
                        obj_name = get(s, "title", pascal_case(prop_name * "AnyOf" * string(i)))
                        traverse(s, obj_name)
                    end
                end
            end
        end
    end
    
    traverse(schema, parent_name, true)
    
    return objects_to_generate
end


# Generates a Julia struct definition from a schema
function generate_structs(schema, struct_name::String, base_path::String, indent::String="")::String
    properties = get(schema, "properties", Dict())
    
    # Merge properties from allOf
    if haskey(schema, "allOf")
        for sub_schema in schema["allOf"]
            merge!(properties, get(sub_schema, "properties", Dict()))
        end
    end
    
    required_fields = get(schema, "required", [])
    
    struct_definition = create_docstring(schema, properties, struct_name, indent)
    struct_definition *= "$(indent)struct $(struct_name)\n"
    
    for (prop_name, prop_schema) in properties
        julia_type = generate_type_string(prop_schema, base_path, struct_name, prop_name)

        if !(prop_name in required_fields)
            julia_type = "Union{Nothing, $(julia_type)}"
        end

        # Add comment for external dependencies
        ref = get(prop_schema, "\$ref", nothing)
        if ref !== nothing && !isempty(URI(ref).path)
            ext_path = basename(URI(ref).path)
            ext_type = pascal_case(split(URI(ref).fragment, "/")[end])
            struct_definition *= "$(indent)    # Depends on $(ext_type) from $(ext_path)\n"
        end
        
        struct_definition *= "$(indent)    $(prop_name)::$(julia_type)\n"
    end
    
    struct_definition *= "$(indent)end\n"

    return struct_definition
end

# Main function to generate and write the file
function generate_julia_types(main_schema_path::String, output_file::String)
    println("Starting schema generation from: $(main_schema_path)\n")

    empty!(SCHEMA_CACHE)

    schema = load_schema(main_schema_path)
    
    all_refs = find_all_refs(schema)
    for ref in all_refs
        if !isempty(URI(ref).path)
            load_schema(normpath(joinpath(dirname(main_schema_path), URI(ref).path)))
        end
    end
    
    generated_code = ""

    root_struct_name = get(schema, "title", "Schema") |>
                       x -> replace(x, r"\s" => "") |>
                       x -> replace(x, r"[^A-Za-z0-9_]" => "")
    
    root_struct_name = isempty(root_struct_name) ? "Schema" : root_struct_name
    
    all_objects = find_all_objects(schema, root_struct_name, main_schema_path)
    
    # Generate structs for all internal and nested objects first
    for (obj_name, obj_schema) in all_objects
        generated_code *= generate_structs(obj_schema, obj_name, main_schema_path) * "\n"
    end
    
    # Generate structs for all root definitions
    for (path, s) in SCHEMA_CACHE
        definitions = get(s, "\$defs", get(s, "definitions", Dict()))
        for (def_name, def_schema) in definitions
            def_struct_name = pascal_case(def_name)
            if get(def_schema, "type", "") == "object"
                generated_code *= generate_structs(def_schema, def_struct_name, path) * "\n"
            elseif haskey(def_schema, "enum")
                # Handle enum types with multiple possible Julia element types
                enum_values = def_schema["enum"]
                enum_types = unique(typeof.(enum_values))
                julia_type = length(enum_types) == 1 ? enum_types[1] : Union{enum_types...}
                
                generated_code *= "const $(def_struct_name)_VALUES = $(repr(enum_values))::Vector{$(string(julia_type))}\n"
                
                docstring = create_docstring(def_schema, Dict(), def_struct_name)
                generated_code *= docstring
                
                generated_code *= "struct $(def_struct_name)\n"
                generated_code *= "    value::$(string(julia_type))\n"
                generated_code *= "    function $(def_struct_name)(value::$(string(julia_type)))\n"
                generated_code *= "        @assert value in $(def_struct_name)_VALUES \"Invalid value for $(def_struct_name): '\$value'\"\n"
                generated_code *= "        new(value)\n"
                generated_code *= "    end\n"
                generated_code *= "end\n\n"
            end
        end
    end

    # Finally, generate the root struct
    generated_code *= generate_structs(schema, root_struct_name, main_schema_path)
    
    open(output_file, "w") do f
        write(f, "# This file was programmatically generated from JSON Schemas.\n")
        write(f, "# Generated on: $(now())\n")
        write(f, "# Do not edit this file directly.\n\n")
        write(f, generated_code)
    end
    
    println("\n✅ Successfully generated Julia types and saved to '$(output_file)'")
end

# Helper function to find all references recursively
function find_all_refs(schema::Dict)
    refs = Set{String}()
    if haskey(schema, "\$ref")
        push!(refs, schema["\$ref"])
    end
    for (key, val) in schema
        if isa(val, Dict)
            union!(refs, find_all_refs(val))
        elseif isa(val, Vector)
            for item in val
                if isa(item, Dict)
                    union!(refs, find_all_refs(item))
                end
            end
        end
    end
    return refs
end
