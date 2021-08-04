using JSON3

include("../src/parser.jl")

folder_for_generated_types = "../examples/acme_parsed_schemas/"

filename = "../examples/acme_schemas/acme_flatschema.json"
json_schema = JSON3.read(read(filename, String))
generate_types(json_schema;
    gen_folder=folder_for_generated_types,
    module_name = "AcmeFlat")

filename = "../examples/acme_schemas/acme_nestedschema.json"
json_schema = JSON3.read(read(filename, String))
generate_types(json_schema;
    gen_folder=folder_for_generated_types,
    module_name = "AcmeNested")

filename = "../examples/acme_schemas/acme_nestedschema_mod.json"
json_schema = JSON3.read(read(filename, String))
generate_types(json_schema;
    gen_folder=folder_for_generated_types,
    module_name = "AcmeNestedMod")