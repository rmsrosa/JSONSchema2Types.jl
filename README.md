# JSONSchema2Types

Parse a JSON Schema to Julia types and, maybe, one day, the other way around.

## Examples

### Acme example from json-schema.org

The examples here were taken from [Getting Started Step-By-Step](https://json-schema.org/learn/getting-started-step-by-step.html#properties), from the [JSON Schema organization](https://json-schema.org), with the [BSD license](https://en.wikipedia.org/wiki/BSD_licenses) (as well as [AFL - Academic Free License](https://opensource.org/licenses/AFL-3.0)); see [json-schema-org/json-schema-org.github.io](https://github.com/json-schema-org/json-schema-org.github.io).

#### Nested schema

Parser is already working (partially) on nested schemas.

For example, suppose we have a file `acme_nestedschema.json` with the following  `jsonschema`:

```json
{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://example.com/product.schema.json",
    "title": "Product",
    "description": "A product from Acme's catalog",
    "type": "object",
    "properties": {
      "productId": {
        "description": "The unique identifier for a product",
        "type": "integer"
      },
      "productName": {
        "description": "Name of the product",
        "type": "string"
      },
      "price": {
        "description": "The price of the product",
        "type": "number",
        "exclusiveMinimum": 0
      },
      "tags": {
        "description": "Tags for the product",
        "type": "array",
        "items": {
          "type": "string"
        },
        "minItems": 1,
        "uniqueItems": true
      },
      "dimensions": {
        "type": "object",
        "properties": {
          "length": {
            "type": "number"
          },
          "width": {
            "type": "number"
          },
          "height": {
            "type": "number"
          }
        },
        "required": [ "length", "width", "height" ]
      }
    },
    "required": [ "productId", "productName", "price" ]
}
```

We can parse it with

```julia
julia> generate_type_module(json_schema, generated_module_dir, "AcmeNested")
```

This creates a module named `AcmeNested` and saves it to file `AcmeNested.jl`

```julia
module AcmeNested

mutable struct Product
    productId::Int
    productName::String
    price::Number
    tags::Array{String}
    dimensions::Dimensions
end

mutable struct Dimensions
    length::Number
    width::Number
    height::Number
end

end # end module
```

Notice the requirements and conditions are not yet enforced, but they will be, via inner constructors.

The descriptions are not used either, but they will be, for constructing a minimal docstring.

### Beerjson

This is my main motivation for doing this. I would like to map all [beerjson](https://github.com/beerjson/beerjson) schema specification to julia types. This is an extensive and intricate schema, so a manual solution would be quite laborious. An aside motivation is in the spirit of open source collaboration, hoping this package, if it ever comes to conclusion, would be helpful to others.

## Design

## License

This is licensed under the [MIT License](https://opensource.org/licenses/MIT); see [LICENSE](LICENSE).
