using JSON3

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

pascal_case(str::AbstractString) = 
    replace(titlecase(replace(str, r"-|_|\." => " ")), " " => "")

function generate_type_module(json_schema::JSON3.Object)

    if Symbol("\$id") ∉ keys(json_schema)
        throw(ArgumentError("json schema missing `:\$id` keyword. No module created."))
    end

    module_name = pascal_case(
        replace(split(json_schema[Symbol("\$id")], '/')[end], ".json" => "")
    )

    generated_string = "module $module_name\n\n"
    generated_string *= generate_types(module_name, json_schema)
    generated_string *= "\n\nend # end module"

    return generated_string
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

    struct_name =
        :title ∈ keys(json_schema) ? 
            json_schema[:title] :
            "Struct$(rand(1000:9999))"

    generated_string = "\nmutable struct $(pascal_case(struct_name))\n"

    generated_string = "\nmutable struct $object_type\n"

    for (k, v) in json_schema[:properties]
        if v[:type] in keys(object_to_types)
            generated_string *= "    $(string(k))::$(object_to_types[v[:type]])\n"
        elseif v[:type] == "array"
            generated_string *= "    $(string(k))::Array{$(object_to_types[v[:items][:type]])}\n"
        elseif v[:type] == "object"
            object_type = pascal_case(string(k))
            generated_string *= "    $(string(k))::$(object_type)\n"
            push!(inner_objects, object_type => v)
        end
    end
    generated_string *= "end\n" # end mutable struct

    if length(inner_objects) > 0
        for (k,v) in inner_objects
            generated_string *= generate_types(k, v)
        end
    end

    return generated_string
end
