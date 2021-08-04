# Translation table for the types
#
# The table does not include types `array` and `object`, which are handled differently
_type_translator = Dict{String,String}(
    "integer" => "Int",
    "string" => "String",
    "number" => string(typeof(1.0)),
    "boolean" => "Bool",
    "null" => "Nothing",
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
        if haskey(_type_translator, k)
            _type_translator[k] = v
        else
            push!(_type_translator, k => v)
        end
    end
    return _type_translator
end

pascal_case(s::AbstractString) = 
    replace(titlecase(s, strict=false), r"-|_|\.| " => "")

function generate_constructor(json_schema::JSON3.Object, ::Val{:oneOf})
    nothing
end

function generate_constructor(json_schema::JSON3.Object, ::Val{:allOf})
    nothing
end

function generate_constructor(json_schema::JSON3.Object, ::Val{:anyOf})
    nothing
end

function generate_constructor(json_schema::JSON3.Object, ::Val{:enum})
    nothing
end

function generate_types(json_schema::JSON3.Object;
        gen_folder::String=".", module_name::String="", filename::String="")

    if Symbol("\$id") ∉ keys(json_schema)
        throw(ArgumentError("json schema missing `:\$id` keyword. No module created."))
    end

    if module_name == ""
        generated_string = generate_types("", json_schema)
    else
        generated_string = "module $module_name\n"
        generated_string *= generate_types("", json_schema)
        generated_string *= "\nend # end module"
    end

    if filename == ""
        if module_name != ""
            filename = "$module_name.jl"
        else
            filename = "JSONSchemaTypes.jl"
        end
    end

    open(joinpath(gen_folder, filename), "w") do io
        write(io, generated_string)
    end

    if module_name == ""
        @info "Types succesfully created in " * 
        "$(joinpath(gen_folder, filename))"
    else
        @info "Module $module_name succesfully created in " * 
            "$(joinpath(gen_folder, filename))"
    end
    return nothing
end

function generate_types(object_name::String, json_schema::JSON3.Object)

    if (:type, :properties) ⊈ keys(json_schema)
        throw(ArgumentError("Empty schema, with no `:properties` and `:type` keywords."))
    end

    if json_schema[:type] != "object"
        throw(ArgumentError("Expecting `object` type; got `$(json_schema[:type])`."))
    end        

    inner_objects = Dict{String, JSON3.Object}()

    if object_name == ""
        object_name =
            :title ∈ keys(json_schema) ? 
                json_schema[:title] :
                "Struct$(rand(1000:9999))"
    end

    include_docstring = false
    generated_docstring = "\n\"\"\"\n    mutable struct $object_name\n"
    if haskey(json_schema, :description)
        include_docstring = true
        generated_docstring *= "\n$(json_schema[:description])\n"
    end

    generated_struct = "\nmutable struct $object_name\n"

    include_docstring_fields = false
    generated_docstring_fields = ""
    for (k, v) in json_schema[:properties]
        if v[:type] in keys(_type_translator)
            generated_struct *= "    $(string(k))::$(_type_translator[v[:type]])\n"
        elseif v[:type] == "array"
            generated_struct *= "    $(string(k))::Array{$(_type_translator[v[:items][:type]])}\n"
        elseif v[:type] == "object"
            object_name = pascal_case(string(k))
            generated_struct *= "    $(string(k))::$(object_name)\n"
            push!(inner_objects, object_name => v)
        end
        generated_docstring_fields *= "   `$(string(k))`:"
        if haskey(v, :description)
            include_docstring_fields = true
            generated_docstring_fields *= " $(v[:description])\n"
        else
            generated_docstring_fields *= "\n"
        end
    end
    generated_struct *= "end\n" # end mutable struct

    if include_docstring_fields == true
        include_docstring == true
        generated_docstring *= "\nFields:\n" * generated_docstring_fields
    end
    if include_docstring == true
        generated_struct = generated_docstring * "\"\"\"" * generated_struct
    end    

    if length(inner_objects) > 0
        for (k,v) in inner_objects
            generated_struct *= generate_types(k, v)
        end
    end

    return generated_struct
end
