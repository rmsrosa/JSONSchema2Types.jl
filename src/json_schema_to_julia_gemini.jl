using JSON
using URIs
using Dates

"""
A Julia module to generate Julia structs from a JSON Schema using JSON.jl.
This version correctly handles 'definitions' and '\$ref' keywords, including external file references.
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

# Example

```jldoctest
julia> pascal_case("foo_bar")
"FooBar"

julia> pascal_case("foo_bar.baz")
"FooBarBaz"

julia> pascal_case("fOO Bar-bAz")
"FOOBarBAz"
```
"""
pascal_case(s::AbstractString) = 
    replace(titlecase(s, strict=false), r" |-|_|\." => "")

# Recursively generates Julia struct definitions
function generate_structs(schema, struct_name::String, base_path::String, indent::String="")::String
    ref = get(schema, "\$ref", nothing)
    if ref !== nothing
        uri = URI(ref)
        if isempty(uri.path)
            # Local reference within the same file (e.g., "#/$defs/MyType")
            def_path = split(uri.fragment, "/")[2:end]
            sub_schema = SCHEMA_CACHE[base_path]
            for key in def_path
                sub_schema = get(sub_schema, key, nothing)
                if sub_schema === nothing
                    error("Reference not found in local schema: $(ref)")
                end
            end
            return generate_structs(sub_schema, struct_name, base_path, indent)
        else
            # External reference
            ext_path = normpath(joinpath(dirname(base_path), uri.path))
            ext_schema = load_schema(ext_path)
            def_path = split(uri.fragment, "/")[2:end]
            sub_schema = ext_schema
            for key in def_path
                sub_schema = get(sub_schema, key, nothing)
                if sub_schema === nothing
                    error("Reference not found in external schema: $(ref)")
                end
            end
            return generate_structs(sub_schema, struct_name, ext_path, indent)
        end
    end
    
    if get(schema, "type", "") != "object"
        return ""
    end

    struct_docstring = ""
    schema_docstring = get(schema, "description", "")
    include_docstring = !isempty(schema_docstring)

    struct_definition = "$(indent)struct $(struct_name)\n"
    
    properties = get(schema, "properties", Dict())
    required_fields = get(schema, "required", [])

    include_docstring_fields = false
    generated_docstring_fields = ""

    for (prop_name, prop_schema) in properties
        @info prop_name

        julia_type = ""
        prop_type = get(prop_schema, "type", "")
        ref = get(prop_schema, "\$ref", nothing)
        @info prop_type

        if ref !== nothing
            uri = URI(ref)
            if isempty(uri.path)
                def_name = split(uri.fragment, "/")[end]
                julia_type = pascal_case(def_name)
            else
                ext_path = normpath(joinpath(dirname(base_path), uri.path))
                def_name = split(uri.fragment, "/")[end]
                julia_type = pascal_case(def_name)
                load_schema(ext_path)
                definitions = get(SCHEMA_CACHE[ext_path], "\$defs", get(SCHEMA_CACHE[ext_path], "definitions", Dict()))
                struct_definition = "# Depends on struct $(julia_type) from $(basename(ext_path))\n" * struct_definition
            end
        elseif haskey(TYPE_MAP, prop_type)
            julia_type = TYPE_MAP[prop_type]
        elseif prop_type == "object"
            nested_struct_name = pascal_case(prop_name)
            struct_definition = generate_structs(prop_schema, nested_struct_name, base_path, indent) * "\n" * struct_definition
            julia_type = nested_struct_name
        elseif prop_type == "array"
            items_schema = get(prop_schema, "items", Dict())
            ref = get(items_schema, "\$ref", nothing)
            items_type = get(items_schema, "type", "")

            if ref !== nothing
                uri = URI(ref)
                def_name = split(uri.fragment, "/")[end]
                julia_type = "Vector{$(pascal_case(def_name))}"
            elseif haskey(TYPE_MAP, items_type)
                julia_type = "Vector{$(TYPE_MAP[items_type])}"
            elseif items_type == "object"
                nested_struct_name = pascal_case(prop_name)
                struct_definition = generate_structs(items_schema, nested_struct_name, base_path, indent) * "\n" * struct_definition
                julia_type = "Vector{$(nested_struct_name)}"
            else
                julia_type = "Vector{Any}"
            end
        else
            julia_type = "Any"
        end

        if !(prop_name in required_fields)
            julia_type = "Union{Nothing, $(julia_type)}"
        end

        field_docstring = get(prop_schema, "description", "")
        @info field_docstring
        if !isempty(field_docstring)
            include_docstring_fields = true
            generated_docstring_fields *= "$(indent)   `$(prop_name)`:  $(field_docstring)\n"
        end
        
        struct_definition *= "$(indent)    $(prop_name)::$(julia_type)\n"
        
    end
    
    struct_definition *= "$(indent)end\n"
    
    if include_docstring_fields
        include_docstring = true
        struct_docstring *= "\nFields:\n" * generated_docstring_fields
    end

    if include_docstring
        struct_definition = "\n\"\"\"\n$(indent)    struct $struct_name\n\n$(schema_docstring)\n" * struct_docstring * "\"\"\"\n" * struct_definition
    end    

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



