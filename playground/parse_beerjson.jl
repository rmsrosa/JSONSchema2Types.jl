using JSON3
using HTTP

include("../src/parser.jl")

uri = "https://raw.githubusercontent.com/beerjson/beerjson/master/json/beer.json"
#uri = "https://raw.githubusercontent.com/beerjson/beerjson/master/json/fermentable.json"
@assert isvalid(HTTP.URI(uri)) "Invalid URI"
json_string = String(HTTP.get(uri).body)
json_schema = JSON3.read(json_string)

folder_for_generated_types = "../examples/beerjson_parsed_schemas/"

generate_types(json_schema;
    gen_folder=folder_for_generated_types,
    module_name = titlecase(first(split(basename(uri), '.')))*"JSON")
