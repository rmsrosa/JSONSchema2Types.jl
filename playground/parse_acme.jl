using JSON3

include("../src/parser.jl")

filename = "../jsonschema_examples/acme_schemas/acme_flatschema.json"
json_schema = JSON3.read(read(filename, String))

println(generate_type_module(json_schema))

filename = "../jsonschema_examples/acme_schemas/acme_nestedschema.json"
json_schema = JSON3.read(read(filename, String))

println(generate_type_module(json_schema))