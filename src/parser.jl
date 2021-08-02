# default translation table (user should be able to use different one to specialize types)
# It will be a `const` when packaged
# It does not include types `array` and `object`, which are handled differently
OBJECT_TO_TYPES = Dict(
    "integer" => "Int",
    "string" => "String",
    "number" => "Number",
    "boolean" => "Bool",
    "null" => "Nothing",
)

pascal_case(s::AbstractString) = 
    replace(titlecase(s, strict=false), r"-|_|\.| " => "")

function generate_type_module(json_schema::JSON3.Object,
        module_dir::String, module_name::String="")

    if module_name == ""
        module_name = "Module"*prod(rand('a':'z', 4))
    end

    if Symbol("\$id") ∉ keys(json_schema)
        throw(ArgumentError("json schema missing `:\$id` keyword. No module created."))
    end

    struct_name =
        :title ∈ keys(json_schema) ? 
            json_schema[:title] :
            "Struct$(rand(1000:9999))"

    generated_string = "module $module_name\n"
    generated_string *= generate_types(struct_name, json_schema)
    generated_string *= "\nend # end module"

    module_filename = "$module_name.jl"
    open(joinpath(module_dir, module_filename), "w") do io
        write(io, generated_string)
    end
    @info "Module $module_name succesfully created in " * 
        "$(joinpath(module_dir, module_filename))"
    return nothing
end

function generate_types(object_type::String, json_schema::JSON3.Object,
        object_to_types::Dict{String,String}=OBJECT_TO_TYPES)

    if (:type, :properties) ⊈ keys(json_schema)
        throw(ArgumentError("Empty schema, with no `:properties` and `:type` keywords."))
    end

    if json_schema[:type] != "object"
        throw(ArgumentError("Expecting `object` type; got `$(json_schema[:type])`."))
    end        

    inner_objects = Dict{String, JSON3.Object}()

    include_docstring = false
    generated_docstring = "\n\"\"\"\n    mutable struct $object_type\n"
    if haskey(json_schema, :description)
        include_docstring = true
        generated_docstring *= "\n$(json_schema[:description])\n"
    end

    generated_struct = "\nmutable struct $object_type\n"

    include_docstring_fields = false
    generated_docstring_fields = ""
    for (k, v) in json_schema[:properties]
        if v[:type] in keys(object_to_types)
            generated_struct *= "    $(string(k))::$(object_to_types[v[:type]])\n"
        elseif v[:type] == "array"
            generated_struct *= "    $(string(k))::Array{$(object_to_types[v[:items][:type]])}\n"
        elseif v[:type] == "object"
            object_type = pascal_case(string(k))
            generated_struct *= "    $(string(k))::$(object_type)\n"
            push!(inner_objects, object_type => v)
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
