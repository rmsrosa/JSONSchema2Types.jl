# Examples

The code on this page is run when the documentation is built. The schemas are in the
`examples/` directory of the repository.

```@setup acme
using JSONSchema2Types
const EXAMPLES = joinpath(pkgdir(JSONSchema2Types), "examples")
const OUT = mktempdir()
# show the generated types, without the runtime code that precedes them
function show_types(file)
    code = read(file, String)
    i = findfirst("End of runtime support", code)
    println(strip(code[findnext('\n', code, last(i) + 1) + 1:end]))
end
```

## A product catalog

This schema is from the
[Getting Started Step-By-Step](https://json-schema.org/learn/getting-started-step-by-step)
guide of the JSON Schema organization. It describes a product with a nested object and a
few constraints:

```@example acme
schema = joinpath(EXAMPLES, "acme_schemas", "acme_nestedschema.json")
print(read(schema, String))
```

Generate a module from it, and load it:

```@example acme
file = generate_module(schema, joinpath(OUT, "ProductTypes.jl"))
include(file)
using .ProductTypes
```

These are the generated types (the rest of the file is the code for reading, writing and
validating, the same in every generated module):

```@example acme
show_types(file)
```

Values are built with keyword constructors. Plain values are converted, and optional fields
can be left out:

```@example acme
p = Product(productId = 1, productName = "An ice sculpture", price = 12.5,
            dimensions = Dict("length" => 7, "width" => 12, "height" => 9.5))
```

```@example acme
p.dimensions
```

and are written as JSON, without the fields that are not set:

```@example acme
print(tojson(p; pretty = true))
```

Reading a document validates it against the schema:

```@example acme
json = """{"productId": 1, "productName": "An ice sculpture", "price": 0}"""
try
    fromjson(Product, json)
catch err
    showerror(stdout, err)
end
```

```@example acme
json = """{"productId": 1, "productName": "Ice", "price": 1, "tags": ["cold", "cold"]}"""
try
    fromjson(Product, json)
catch err
    showerror(stdout, err)
end
```

## A schema referenced by its `$id`

Another version of the product schema refers to a separate schema for the location of the
warehouse by its `$id`, `https://example.com/geographical-location.schema.json`. The file
with that schema is given with the `schemas` keyword:

```@example acme
file = generate_module(joinpath(EXAMPLES, "acme_schemas", "acme_withreferenceschema.json"),
    joinpath(OUT, "WarehouseTypes.jl"); module_name = "WarehouseTypes",
    schemas = [joinpath(EXAMPLES, "acme_schemas", "acme_tobereferredschema.json")])
include(file)
using .WarehouseTypes: Product as WarehouseProduct, LongitudeAndLatitude
data = joinpath(EXAMPLES, "acme_schemas", "acme_data.json")
print(read(data, String))
```

```@example acme
product = WarehouseTypes.readjson(WarehouseProduct, data)
product.warehouseLocation
```

The referenced schema has the title "Longitude and Latitude", which gives the name of its
type, `LongitudeAndLatitude`.

## `oneOf`, `anyOf`, `allOf` and `not`

```@setup combined
using JSONSchema2Types
const EXAMPLES = joinpath(pkgdir(JSONSchema2Types), "examples")
const OUT = mktempdir()
```

This schema shows the keywords for combining schemas:

```@example combined
schema = joinpath(EXAMPLES, "more_schemas", "combined_schema.json")
print(read(schema, String))
```

```@example combined
file = generate_module(schema, joinpath(OUT, "CombinedTypes.jl"); module_name = "CombinedTypes")
include(file)
using .CombinedTypes
fieldtypes(CombinedSchemaExample)
```

The options of `oneOf` have titles, so they are the types `Person` and `Company`. The
options of `anyOf` have none, so their names are made from the parent and the property.
The `allOf` is merged into a single type, and the `not` is checked at runtime. When reading,
the option that fits is chosen:

```@example combined
json = """
{
  "one_of_user": {"user_type": "company", "company_name": "Acme"},
  "any_of_identifier": {"sku": "A-1"},
  "all_of_request": {"payload": {}, "api_key": "k", "timestamp": "2026-11-13"},
  "not_a_password": "s3cret"
}
"""
x = fromjson(RootType, json)
x.one_of_user
```

and the `not` is enforced:

```@example combined
try
    fromjson(RootType, replace(json, "s3cret" => "password"))
catch err
    showerror(stdout, err)
end
```
