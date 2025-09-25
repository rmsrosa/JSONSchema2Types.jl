include("../src/newparser.jl")

generate_julia_types("examples/more_schemas/order_schema.json", "examples/more_parsed_schemas/schema_types.jl")

generate_julia_types("examples/more_schemas/combined_schema.json", "examples/more_parsed_schemas/combined_schema_types.jl")

generate_julia_types("examples/more_schemas/enum_schema.json", "examples/more_parsed_schemas/enum_schema_types.jl")

generate_julia_types("examples/beerjson-1.0.1/json/beer.json", "examples/beerjson_parsed_schemas/beerjson_schema_types_gemini.jl")