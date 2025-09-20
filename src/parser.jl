# Translation table for the types
#
# The table does not include types `array` and `object`, which are handled differently
_type_translator = Dict{String,String}(
    "integer" => "Int",
    "string"  => "String",
    "number"  => string(typeof(1.0)),
    "boolean" => "Bool",
    "null"    => "Nothing",
)

"""
    set_translation(pairs::Pair{String, String}...)

The translation table from JSONSchema type to Julia type is defined initially by

    Dict{String,String}(
        "integer" => "Int",
        "string" => "String",
        "number" => string(typeof(1.0)),
        "boolean" => "Bool",
        "null" => "Nothing",
    )

The function `set_translation()` can be used to change one or more translations.

# Example

```jldoctest
julia> set_translation("integer" => "Int16")
Dict{String, String} with 5 entries:
  "string"  => "String"
  "number"  => "Float64"
  "integer" => "Int16"
  "null"    => "Nothing"
  "boolean" => "Bool"

julia> set_translation("integer" => "Int32", "number" => "Float32")
Dict{String, String} with 5 entries:
  "string"  => "String"
  "number"  => "Float32"
  "integer" => "Int32"
  "null"    => "Nothing"
  "boolean" => "Bool"

julia> set_translation("integer" => "Integer", "number" => "Number", "string" => "AbstractString")
  Dict{String, String} with 5 entries:
    "string"  => "AbstractString"
    "number"  => "Number"
    "integer" => "Integer"
    "null"    => "Nothing"
    "boolean" => "Bool"
```
"""
function set_translation(pairs::Pair{String, String}...)
    for (k,v) in pairs
        _type_translator[k] = v
    end
    return _type_translator
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

# Placeholders for future extensions
function generate_constructor(json_schema::JSON3.Object, ::Val{:oneOf}) nothing end
function generate_constructor(json_schema::JSON3.Object, ::Val{:allOf}) nothing end
function generate_constructor(json_schema::JSON3.Object, ::Val{:anyOf}) nothing end
function generate_constructor(json_schema::JSON3.Object, ::Val{:enum})  nothing end

"""
    generate_types(json_schema::JSON3.Object; gen_folder=".", module_name="", filename="")

Generate Julia `mutable struct` definitions from a JSON schema and write them to a file.
If `module_name` is provided, wrap the structs in a module.
"""
function generate_types(json_schema::JSON3.Object;
        gen_folder::String=".", module_name::String="", filename::String="")

    # Relaxed: allow schemas without $id, fallback to title
    if Symbol("\$id") ∉ keys(json_schema) && :title ∉ keys(json_schema)
        throw(ArgumentError("Schema missing both `:\$id` and `:title`. No module created."))
    end

    generated_string = if module_name == ""
        generate_types("", json_schema)
    else
        "module $module_name\n" *
        generate_types("", json_schema) *
        "\nend # module $module_name"
    end

    if filename == ""
        filename = module_name != "" ? "$module_name.jl" : "JSONSchemaTypes.jl"
    end

    open(joinpath(gen_folder, filename), "w") do io
        write(io, generated_string)
    end

    msg = module_name == "" ?
        "Types successfully created in $(joinpath(gen_folder, filename))" :
        "Module $module_name successfully created in $(joinpath(gen_folder, filename))"
    @info msg

    return nothing
end

function generate_types(object_name::String, json_schema::JSON3.Object)
    if (:type, :properties) ⊈ keys(json_schema)
        throw(ArgumentError("Schema missing `:properties` or `:type`."))
    end
    if json_schema[:type] != "object"
        throw(ArgumentError("Expecting `object` type; got `$(json_schema[:type])`."))
    end        

    inner_objects = Dict{String, JSON3.Object}()

    if object_name == ""
        object_name = haskey(json_schema, :title) ?
            pascal_case(String(json_schema[:title])) :
            "Struct$(rand(1000:9999))"
    end

    include_docstring = false
    generated_docstring = "\n\"\"\"\n    mutable struct $object_name\n"
    if haskey(json_schema, :description)
        include_docstring = true
        generated_docstring *= "\n$(json_schema[:description])\n"
    end

    generated_struct = "\nmutable struct $object_name\n"

    # Handle required fields
    required = Set(get(json_schema, :required, String[]))

    include_docstring_fields = false
    generated_docstring_fields = ""

    for (k, v) in json_schema[:properties]
        fieldname = string(k)

        julia_type =
            if haskey(v, Symbol("\$ref"))
                "Ref"
            elseif !haskey(v, :type)
                "NoType"
            elseif v[:type] in keys(_type_translator)
                _type_translator[v[:type]]
            elseif v[:type] == "array"
                if haskey(v[:items], :type)
                    "Vector{$(_type_translator[v[:items][:type]])}"
                else
                    "Vector{NoType}"
                end
            elseif v[:type] == "object"
                inner_name = pascal_case(fieldname)
                push!(inner_objects, inner_name => v)
                inner_name
            else
                "Any"
            end

        field_type = fieldname in required ? julia_type : "Union{Nothing,$julia_type}"
        generated_struct *= "    $fieldname::$field_type\n"

        generated_docstring_fields *= "   `$fieldname`:"
        if haskey(v, :description)
            include_docstring_fields = true
            generated_docstring_fields *= " $(v[:description])\n"
        else
            generated_docstring_fields *= "\n"
        end
    end

    generated_struct *= "end\n" # end mutable struct

    if include_docstring_fields
        include_docstring = true
        generated_docstring *= "\nFields:\n" * generated_docstring_fields
    end
    if include_docstring
        generated_struct = generated_docstring * "\"\"\"" * generated_struct
    end    

    if !isempty(inner_objects)
        for (k,v) in inner_objects
            generated_struct *= generate_types(k, v)
        end
    end

    return generated_struct
end
