using JSON
using URIs
using Dates
using UUIDs

include("../src/newestparser.jl")

generate_from_schema("examples/more_schemas/order_schema.json", "examples/more_newest_parsed_schemas/order_schema.jl")

generate_from_schema("examples/more_schemas/combined_schema.json", "examples/more_newest_parsed_schemas/combined_schema_types.jl")

generate_from_schema("examples/more_schemas/enum_schema.json", "examples/more_newest_parsed_schemas/enum_schema_types.jl")

generate_from_schema("examples/beerjson-1.0.1/json/beer.json", "examples/beerjson_parsed_schemas/beerjson_schema_newest_types.jl")