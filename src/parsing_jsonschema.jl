using JSON3

# default translation table (user should be able to use different one to specialize types)
objects_to_types = Dict(
    "integer" => "Int",
    "string" => "String",
    "number" => "Number",
    "array" => "Array",
    "boolean" => "Bool",
    "null" => "Nothing",
    "object" => "Object" # this should actually recurse
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
    generated_string *= generate_types(json_schema)
    generated_string *= "\n\nend # end module"

    return generated_string
end

function generate_types(json_schema::JSON3.Object)

    if (:type, :properties) ⊈ keys(json_schema)
        throw(ArgumentError("Empty schema, with no `:properties` and `:type` keywords."))
    end

    if json_schema[:type] == "object"
        struct_name =
            :title ∈ keys(json_schema) ? 
                json_schema[:title] :
                "Struct$(random(1000:9999))"

        generated_string = "\nmutable struct $(pascal_case(struct_name))\n"

        for (k, v) in json_schema[:properties]
            generated_string *= "    $(string(k))::$(objects_to_types[v[:type]])\n"
        end
        generated_string *= "end" # end mutable struct
    else
        generated_string = ""
    end
    return generated_string
end

#=     if :type ∉ keys(json_schema)
        throw(ArgumentError("json schema missing `:type` keyword"))
    end
    
    if json_schema[:type] == "object"
        parsed_str *= "\nmutable struct "
    end =#

filename = "../jsonschema_examples/acme_schemas/acme_flatschema.json"
json_schema = JSON3.read(read(filename, String))

println(generate_type_module(json_schema))