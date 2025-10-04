# Filename: generate_types.jl

#module JSONSchemaParser

using JSON
using URIs
using Dates
using UUIDs

# --- Core Mappings & Cache ---
const TYPE_MAP = Dict(
    "string" => "String", "number" => "Float64", "integer" => "Int64", "boolean" => "Bool"
)
const FORMAT_MAP = Dict(
    "date-time" => "DateTime", "date" => "Date", "time" => "Time", "uri" => "URI", "uuid" => "UUID"
)
const SCHEMA_CACHE = Dict{String, Any}()

# --- Utility Functions ---

function load_schema(filepath::String)::Dict{String, Any}
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

pascal_case(s::AbstractString) = replace(titlecase(s, strict=false), r" |-|_|\." => "")

function merge_allOf(schema::Dict{String, Any})::Dict{String, Any}
    if !haskey(schema, "allOf")
        return schema
    end
    merged_schema = deepcopy(schema)
    all_of_schemas = pop!(merged_schema, "allOf")
    for sub_schema in all_of_schemas
        if haskey(sub_schema, "properties")
            merged_schema["properties"] = merge(get(merged_schema, "properties", Dict()), sub_schema["properties"])
        end
        if haskey(sub_schema, "required")
            merged_schema["required"] = unique(vcat(get(merged_schema, "required", []), sub_schema["required"]))
        end
    end
    return merged_schema
end


# --- Docstring & Type Generation ---

"""
    create_docstring(schema, properties, struct_name) -> String

Generates a multi-line docstring including the struct description and field descriptions.
"""
function create_docstring(schema::Dict, properties::Dict, struct_name::String)::String
    description = get(schema, "description", "")
    has_field_docs = any(haskey(p, "description") for p in values(properties))
    
    docstring_content = "    $(struct_name)\n\n"
    if !isempty(description)
        docstring_content *= "    $(description)\n"
    end

    if has_field_docs
        docstring_content *= "\n    Fields:\n"
        for (prop_name, prop_schema) in properties
            field_description = get(prop_schema, "description", "")
            if !isempty(field_description)
                docstring_content *= "    `$(prop_name)`: $(field_description)\n"
            end
        end
    end

    return "\"\"\"\n$(docstring_content)\"\"\"\n"
end

function generate_type_string(schema::Dict, base_path::String, parent_struct_name::String, prop_name::String="")::String
    if haskey(schema, "\$ref")
        ref = schema["\$ref"]
        uri = URI(ref)
        def_name = pascal_case(split(uri.fragment, "/")[end])
        if !isempty(uri.path)
            ext_path = normpath(joinpath(dirname(base_path), uri.path))
            load_schema(ext_path)
        end
        return def_name
    end

    prop_type = get(schema, "type", "any")
    if isa(prop_type, Vector)
        non_null_types = filter(t -> t != "null", prop_type)
        if isempty(non_null_types)
            return "Nothing"
        elseif length(non_null_types) == 1
            schema_copy = copy(schema)
            schema_copy["type"] = first(non_null_types)
            return generate_type_string(schema_copy, base_path, parent_struct_name, prop_name)
        else
            types = [generate_type_string(Dict("type"=>t), base_path, parent_struct_name, prop_name) for t in non_null_types]
            return "Union{" * join(unique(types), ", ") * "}"
        end
    end

    if haskey(schema, "oneOf") || haskey(schema, "anyOf")
        key = haskey(schema, "oneOf") ? "oneOf" : "anyOf"
        types = [generate_type_string(s, base_path, parent_struct_name, prop_name * string(i)) for (i, s) in enumerate(schema[key])]
        return "Union{" * join(unique(types), ", ") * "}"
    end
    
    if prop_type == "object"
        return pascal_case(parent_struct_name * pascal_case(prop_name))
    elseif prop_type == "array"
        items_schema = get(schema, "items", Dict())
        item_name = get(items_schema, "title", pascal_case(parent_struct_name * pascal_case(prop_name)))
        items_type_str = generate_type_string(items_schema, base_path, parent_struct_name, item_name)
        return "Vector{$(items_type_str)}"
    end
    
    if prop_type == "string" && haskey(schema, "format")
        return get(FORMAT_MAP, schema["format"], "String")
    end

    return get(TYPE_MAP, prop_type, "Any")
end

function find_all_objects(schema::Dict, parent_name::String, base_path::String)::Dict{String, Any}
    objects_to_generate = Dict{String, Any}()
    function traverse(sub_schema, sub_name::String)
        s = merge_allOf(sub_schema)
        if get(s, "type", "") == "object" && !haskey(s, "\$defs") && !haskey(s, "definitions")
            if !haskey(objects_to_generate, sub_name)
                objects_to_generate[sub_name] = s
            end
        end
        for (prop_name, prop_schema) in get(s, "properties", Dict())
            prop_type = get(prop_schema, "type", "")
            if prop_type == "object"
                traverse(prop_schema, pascal_case(sub_name * pascal_case(prop_name)))
            elseif prop_type == "array" && get(get(prop_schema, "items", Dict()), "type", "") == "object"
                items_schema = prop_schema["items"]
                item_name = get(items_schema, "title", pascal_case(sub_name * pascal_case(prop_name)))
                traverse(items_schema, pascal_case(item_name))
            end
        end
    end
    traverse(schema, parent_name)
    return objects_to_generate
end

function generate_structs(schema::Dict, struct_name::String, base_path::String)::String
    schema = merge_allOf(schema)
    properties = get(schema, "properties", Dict())
    required_fields = get(schema, "required", [])
    
    docstring = create_docstring(schema, properties, struct_name)

    struct_def = "struct $(struct_name)\n"
    fields = []
    for (prop_name, prop_schema) in properties
        julia_type = generate_type_string(prop_schema, base_path, struct_name, prop_name)
        
        prop_type = get(prop_schema, "type", [])
        is_nullable = isa(prop_type, Vector) && "null" in prop_type
        is_optional = (prop_name ∉ required_fields) || is_nullable
        final_type = is_optional ? "Union{Nothing, $(julia_type)}" : julia_type
        
        if haskey(prop_schema, "\$ref")
            uri = URI(prop_schema["\$ref"])
            if !isempty(uri.path)
                ext_path = basename(uri.path)
                ext_type = pascal_case(split(uri.fragment, "/")[end])
                struct_def *= "    # Depends on $(ext_type) from $(ext_path)\n"
            end
        end
        
        struct_def *= "    $(prop_name)::$(final_type)\n"
        push!(fields, prop_name)
    end
    
    constructor = "    function $(struct_name)(;"
    constructor_params = [haskey(p_schema, "default") ? "$(p_name) = $(repr(p_schema["default"]))" : p_name for (p_name, p_schema) in properties]
    constructor *= join(constructor_params, ", ") * ")\n"
    
    validations = ""
    for (prop_name, prop_schema) in properties
        if haskey(prop_schema, "pattern")
             pat = repr(prop_schema["pattern"])
             validations *= "        if !isnothing($(prop_name))\n"
             validations *= "            @assert occursin(Regex($pat), $(prop_name)) \"`$(prop_name)` must match the required pattern\"\n"
             validations *= "        end\n"
        end
    end
    constructor *= validations
    
    constructor *= "        return new($(join(fields, ", ")))\n    end\n"
    struct_def *= "\n" * constructor * "end\n"
    
    return docstring * struct_def
end


# --- Main Orchestration ---

function find_all_refs(schema::Any)::Set{String}
    refs = Set{String}()
    if isa(schema, Dict)
        if haskey(schema, "\$ref"); push!(refs, schema["\$ref"]); end
        for val in values(schema); union!(refs, find_all_refs(val)); end
    elseif isa(schema, Vector)
        for item in schema; union!(refs, find_all_refs(item)); end
    end
    return refs
end

function generate_from_schema(main_schema_path::String, output_file::String)
    println("🚀 Starting schema generation from: $(main_schema_path)")
    empty!(SCHEMA_CACHE)
    
    main_schema = load_schema(main_schema_path)
    all_refs = find_all_refs(main_schema)
    for ref in all_refs
        uri = URI(ref)
        if !isempty(uri.path)
            load_schema(normpath(joinpath(dirname(main_schema_path), uri.path)))
        end
    end
    
    generated_code = ""
    generated_types = Set{String}()
    
    for (path, schema) in SCHEMA_CACHE
        definitions = get(schema, "\$defs", get(schema, "definitions", Dict()))
        for (def_name, def_schema) in definitions
            struct_name = pascal_case(def_name)
            if struct_name ∉ generated_types
                generated_code *= generate_structs(def_schema, struct_name, path) * "\n\n"
                push!(generated_types, struct_name)
            end
        end
    end

    root_struct_name = pascal_case(get(main_schema, "title", "RootType"))
    
    all_objects = find_all_objects(main_schema, root_struct_name, main_schema_path)
    for (obj_name, obj_schema) in all_objects
        if obj_name ∉ generated_types
            generated_code *= generate_structs(obj_schema, obj_name, main_schema_path) * "\n\n"
            push!(generated_types, obj_name)
        end
    end

    if root_struct_name ∉ generated_types
        generated_code *= generate_structs(main_schema, root_struct_name, main_schema_path)
    end
    
    open(output_file, "w") do f
        write(f, "# This file was programmatically generated from JSON Schemas.\n")
        write(f, "# Generated on: $(now())\n")
        write(f, "# Do not edit this file directly.\n\n")
        write(f, "using Dates, URIs, UUIDs\n\n")
        write(f, generated_code)
    end
    
    println("\n✅ Successfully generated Julia types and saved to '$(output_file)'")
end

#end # module

# --- Example Usage ---
# To run this script: julia generate_types.jl
# JSONSchemaParser.generate_from_schema("path/to/your/schema.json", "path/to/output/MyTypes.jl")