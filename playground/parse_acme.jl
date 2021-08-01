using JSON3

include("../src/parser.jl")

generated_module_dir = "../examples/acme_parsed_schemas/"

filename = "../examples/acme_schemas/acme_flatschema.json"
json_schema = JSON3.read(read(filename, String))
generate_type_module(json_schema, generated_module_dir, "AcmeFlat")

filename = "../examples/acme_schemas/acme_nestedschema.json"
json_schema = JSON3.read(read(filename, String))
generate_type_module(json_schema, generated_module_dir, "AcmeNested")
