using JSON
using URIs
using Dates

"""
A Julia module to generate Julia structs from a JSON Schema.
This version handles 'definitions' and '\$ref' keywords, including external file references,
and generates docstrings from schema descriptions. It also adds support for
'oneOf', 'anyOf', 'allOf', and 'not' keywords.
"""
#module SchemaGenerator

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

    if haskey(schema, "oneOf")
        types = [generate_type_string(s, base_path, parent_struct_name, prop_name) for s in schema["oneOf"]]
        return "Union{" * join(types, ", ") * "}"
    elseif haskey(schema, "anyOf")
        types = [generate_type_string(s, base_path, parent_struct_name, prop_name) for s in schema["anyOf"]]
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
        items_type_str = generate_type_string(items_schema, base_path, parent_struct_name, prop_name)
        if get(items_schema, "type", "") == "object"
            items_type_str = pascal_case(parent_struct_name * pascal_case(prop_name)) |> x -> endswith(x, "s") ? x[1:end-1] : x
        end
        return "Vector{$(items_type_str)}"
    else
        return "Any"
    end
end


# Recursively generates Julia struct definitions
function generate_structs(schema, struct_name::String, base_path::String, indent::String="")::String
    if get(schema, "type", "") != "object"
        # This function should only be called for object types
        return ""
    end

    properties = get(schema, "properties", Dict())
    if haskey(schema, "allOf")
        for sub_schema in schema["allOf"]
            merge!(properties, get(sub_schema, "properties", Dict()))
        end
    end
    required_fields = get(schema, "required", [])
    
    generated_nested_structs = ""
    for (prop_name, prop_schema) in properties
        prop_type = get(prop_schema, "type", "")
        if prop_type == "object"
            nested_struct_name = pascal_case(struct_name * pascal_case(prop_name))
            generated_nested_structs *= generate_structs(prop_schema, nested_struct_name, base_path, indent) * "\n"
        elseif prop_type == "array"
            items_schema = get(prop_schema, "items", Dict())
            if get(items_schema, "type", "") == "object"
                nested_struct_name = pascal_case(struct_name * pascal_case(prop_name)) |> x -> endswith(x, "s") ? x[1:end-1] : x
                generated_nested_structs *= generate_structs(items_schema, nested_struct_name, base_path, indent) * "\n"
            end
        end
    end
    
    struct_definition = generated_nested_structs
    struct_definition *= create_docstring(schema, properties, struct_name, indent)
    struct_definition *= "$(indent)struct $(struct_name)\n"
    
    for (prop_name, prop_schema) in properties
        julia_type = generate_type_string(prop_schema, base_path, struct_name, prop_name)

        if !(prop_name in required_fields)
            julia_type = "Union{Nothing, $(julia_type)}"
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

    for (path, s) in SCHEMA_CACHE
        definitions = get(s, "\$defs", get(s, "definitions", Dict()))
        for (def_name, def_schema) in definitions
            def_struct_name = pascal_case(def_name)
            generated_code *= generate_structs(def_schema, def_struct_name, path) * "\n"
        end
    end

    root_struct_name = get(schema, "title", "Schema") |>
                       x -> replace(x, r"\s" => "") |>
                       x -> replace(x, r"[^A-Za-z0-9_]" => "")
    
    root_struct_name = isempty(root_struct_name) ? "Schema" : root_struct_name
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

#end # module SchemaGenerator

