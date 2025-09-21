using JSON3

"""
    JSONSchemaToJulia

A module for converting JSON Schema object definitions to Julia parametric types.
"""
module JSONSchemaToJulia

using JSON3

export generate_julia_types, parse_schema_file

"""
    julia_type_from_json_type(json_type::String) -> String

Convert JSON Schema type to Julia type string.
"""
function julia_type_from_json_type(json_type::String)::String
    type_map = Dict(
        "string" => "String",
        "integer" => "Int",
        "number" => "Float64",
        "boolean" => "Bool",
        "array" => "Vector",
        "object" => "Dict{String,Any}",
        "null" => "Nothing"
    )
    return get(type_map, json_type, "Any")
end

"""
    extract_ref_name(ref::String) -> String

Extract type name from a JSON Schema reference.
"""
function extract_ref_name(ref::String)::String
    # Handle both #/definitions/TypeName and #/$defs/TypeName
    parts = split(ref, "/")
    return length(parts) >= 3 ? parts[end] : ref
end

"""
    process_property(prop_name::String, prop_schema::Dict) -> Tuple{String, String}

Process a single property and return (field_name, field_type).
"""
function process_property(prop_name::String, prop_schema::Dict)::Tuple{String,String}
    if haskey(prop_schema, "\$ref")
        ref_type = extract_ref_name(prop_schema["\$ref"])
        return (prop_name, ref_type * "{T}")
    elseif haskey(prop_schema, "type")
        json_type = prop_schema["type"]
        if json_type == "array" && haskey(prop_schema, "items")
            items_schema = prop_schema["items"]
            if haskey(items_schema, "\$ref")
                item_type = extract_ref_name(items_schema["\$ref"])
                return (prop_name, "Vector{$(item_type){T}}")
            elseif haskey(items_schema, "type")
                item_type = julia_type_from_json_type(items_schema["type"])
                return (prop_name, "Vector{$(item_type)}")
            else
                return (prop_name, "Vector{Any}")
            end
        else
            julia_type = julia_type_from_json_type(json_type)
            return (prop_name, julia_type)
        end
    elseif haskey(prop_schema, "anyOf") || haskey(prop_schema, "oneOf")
        # For union types, we'll use Any for simplicity
        return (prop_name, "Any")
    else
        return (prop_name, "Any")
    end
end

"""
    generate_struct_definition(type_name::String, object_schema::Dict) -> String

Generate a Julia struct definition from an object schema.
"""
function generate_struct_definition(type_name::String, object_schema::Dict)::String
    lines = String[]
    
    # Add documentation if description exists
    if haskey(object_schema, "description")
        push!(lines, "\"\"\"\n    $(type_name){T}\n\n$(object_schema["description"])\n\"\"\"")
    end
    
    # Start struct definition
    push!(lines, "struct $(type_name){T}")
    
    # Process properties
    if haskey(object_schema, "properties")
        properties = object_schema["properties"]
        required_fields = get(object_schema, "required", String[])
        
        for (prop_name, prop_schema) in properties
            field_name, field_type = process_property(prop_name, prop_schema)
            
            # Make optional fields Union{T, Nothing} if not required
            if !(prop_name in required_fields)
                field_type = "Union{$(field_type), Nothing}"
            end
            
            # Add field with comment if description exists
            if haskey(prop_schema, "description")
                push!(lines, "    $(field_name)::$(field_type)  # $(prop_schema["description"])")
            else
                push!(lines, "    $(field_name)::$(field_type)")
            end
        end
    end
    
    # If no properties, add a dummy field to make it a valid struct
    if !haskey(object_schema, "properties") || isempty(object_schema["properties"])
        push!(lines, "    _dummy::T  # Placeholder for empty object")
    end
    
    push!(lines, "end")
    push!(lines, "")
    
    return join(lines, "\n")
end

"""
    extract_object_definitions(schema::Dict) -> Dict{String, Dict}

Extract all object definitions from a schema, including nested ones.
"""
function extract_object_definitions(schema::Dict)::Dict{String,Dict}
    objects = Dict{String,Dict}()
    
    # Check main schema if it's an object
    if get(schema, "type", "") == "object"
        objects["RootObject"] = schema
    end
    
    # Check definitions/\$defs
    for defs_key in ["definitions", "\$defs"]
        if haskey(schema, defs_key)
            definitions = schema[defs_key]
            for (def_name, def_schema) in definitions
                if get(def_schema, "type", "") == "object"
                    objects[def_name] = def_schema
                end
            end
        end
    end
    
    # Recursively check nested schemas
    function extract_nested(obj::Dict, prefix::String="")
        for (key, value) in obj
            if isa(value, Dict)
                if get(value, "type", "") == "object" && key != "properties"
                    nested_name = prefix == "" ? key : "$(prefix)_$(key)"
                    objects[nested_name] = value
                end
                extract_nested(value, key)
            end
        end
    end
    
    extract_nested(schema)
    
    return objects
end

"""
    generate_julia_types(schema::JSON3.Object; module_name::String="GeneratedTypes") -> String

Generate Julia code with parametric types from a JSON schema.
"""
function generate_julia_types(schema::Dict; module_name::String="GeneratedTypes")::String
    objects = extract_object_definitions(schema)
    
    if isempty(objects)
        return "# No object types found in schema\n"
    end
    
    lines = String[]
    
    # Module header
    push!(lines, "# Generated Julia types from JSON Schema")
    push!(lines, "# Generated on $(now())")
    push!(lines, "")
    push!(lines, "module $(module_name)")
    push!(lines, "")
    push!(lines, "export " * join(keys(objects), ", "))
    push!(lines, "")
    
    # Generate struct definitions
    for (type_name, object_schema) in objects
        struct_def = generate_struct_definition(type_name, object_schema)
        push!(lines, struct_def)
    end
    
    # Module footer
    push!(lines, "end # module $(module_name)")
    
    return join(lines, "\n")
end

"""
    parse_schema_file(filepath::String; module_name::String="GeneratedTypes") -> String

Parse a JSON schema file and generate Julia types.
"""
function parse_schema_file(filepath::String; module_name::String="GeneratedTypes")::String
    schema_text = read(filepath, String)
    schema = JSON3.read(schema_text)
    return generate_julia_types(schema; module_name=module_name)
end

"""
    write_julia_file(julia_code::String, output_path::String)

Write generated Julia code to a file.
"""
function write_julia_file(julia_code::String, output_path::String)
    open(output_path, "w") do io
        write(io, julia_code)
    end
    println("Julia types written to: $(output_path)")
end

end # module JSONSchemaToJulia

# Example usage
if abspath(PROGRAM_FILE) == @__FILE__
    using .JSONSchemaToJulia
    
    # Example schema
    example_schema = Dict(
        "\$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "properties" => Dict(
            "users" => Dict(
                "type" => "array",
                "items" => Dict("\$ref" => "#/\$defs/User")
            )
        ),
        "\$defs" => Dict(
            "User" => Dict(
                "type" => "object",
                "description" => "A user in the system",
                "properties" => Dict(
                    "id" => Dict("type" => "integer", "description" => "User ID"),
                    "name" => Dict("type" => "string", "description" => "User name"),
                    "email" => Dict("type" => "string", "description" => "Email address"),
                    "profile" => Dict("\$ref" => "#/\$defs/Profile")
                ),
                "required" => ["id", "name"]
            ),
            "Profile" => Dict(
                "type" => "object",
                "properties" => Dict(
                    "bio" => Dict("type" => "string"),
                    "age" => Dict("type" => "integer"),
                    "tags" => Dict(
                        "type" => "array",
                        "items" => Dict("type" => "string")
                    )
                )
            )
        )
    )
    
    # Generate and print Julia types
    julia_code = generate_julia_types(example_schema; module_name="ExampleTypes")
    println(julia_code)
    
    # Optionally write to file
    # write_julia_file(julia_code, "generated_types.jl")
end