# Generate the Julia modules in `examples/generated/` from the schemas in `examples/`.
#
# Run it from the root of the repository with
#
#     julia --project=. examples/generate_examples.jl

using JSONSchema2Types

const EXAMPLES = @__DIR__
const OUT = joinpath(EXAMPLES, "generated")

ex(path...) = joinpath(EXAMPLES, path...)

# Acme examples from json-schema.org
generate_module(ex("acme_schemas", "acme_flatschema.json"), joinpath(OUT, "AcmeFlat.jl");
    module_name = "AcmeFlat")
generate_module(ex("acme_schemas", "acme_nestedschema.json"), joinpath(OUT, "AcmeNested.jl");
    module_name = "AcmeNested")
generate_module(ex("acme_schemas", "acme_nestedschema_mod.json"), joinpath(OUT, "AcmeNestedMod.jl");
    module_name = "AcmeNestedMod")
generate_module(ex("acme_schemas", "acme_withreferenceschema.json"), joinpath(OUT, "AcmeWithReference.jl");
    module_name = "AcmeWithReference",
    schemas = [ex("acme_schemas", "acme_tobereferredschema.json")])

# Other examples, with `$ref`s to other files, `enum`, `oneOf`, `anyOf`, `allOf` and `not`
generate_module(ex("more_schemas", "order_schema.json"), joinpath(OUT, "Order.jl");
    module_name = "OrderTypes")
generate_module(ex("more_schemas", "combined_schema.json"), joinpath(OUT, "Combined.jl");
    module_name = "Combined")
generate_module(ex("more_schemas", "enum_schema.json"), joinpath(OUT, "Enum.jl");
    module_name = "EnumExample")

# BeerJSON 1.0.1, split into one file per schema file; load it with
# `include("examples/generated/BeerJSONTypes/BeerJSONTypes.jl")`
generate_module(ex("beerjson-1.0.1", "json", "beer.json"), joinpath(OUT, "BeerJSONTypes");
    root_name = "BeerJSON", module_name = "BeerJSONTypes", split = true)
