# JSONSchema2Types

Generate Julia types from a [JSON Schema](https://json-schema.org), together with functions
to read and write JSON documents that conform to the schema.

The main motivation is the [BeerJSON](https://github.com/beerjson/beerjson) schema, which is
large and intricate, so writing the types by hand would take a lot of work. The package is
general, though, and should be useful for other schemas as well.

## Usage

```julia
julia> using JSONSchema2Types

julia> generate_module("examples/beerjson-1.0.1/json/beer.json", "BeerJSON.jl";
           root_name = "BeerJSON", module_name = "BeerJSON")
"BeerJSON.jl"
```

This reads the schema, and every schema file it references with `$ref`. It then writes a
self-contained module to `BeerJSON.jl`, which depends only on
[JSON.jl](https://github.com/JuliaIO/JSON.jl):

```julia
julia> include("BeerJSON.jl"); using .BeerJSON

julia> doc = readjson(RootType, "test/beerjson-1.0.1-samples/real/SourMash.json");

julia> recipe = doc.beerjson.recipes[1];

julia> recipe.name, recipe.type
("Sour Mash", RecipeTypeType("all grain"))

julia> recipe.batch_size
VolumeType(VolumeUnitType("gal"), 12.0)

julia> writejson("SourMash-copy.json", doc);   # identical content to the original
```

Values are validated when they are constructed or read. Construct them with keyword
arguments. Plain values (strings, numbers, dicts) are converted automatically:

```julia
julia> VolumeType(unit = "l", value = 20)
VolumeType(VolumeUnitType("l"), 20.0)

julia> VolumeType(unit = "litre", value = 20)
ERROR: SchemaValidationError: invalid value "litre" for `VolumeUnitType`; allowed values are "ml", "l", "tsp", ...
```

The generated module exports:

* the generated types, plus `RootType`, an alias for the type of the root of the schema;
* `readjson(T, filename)` and `fromjson(T, string)` to read a JSON document into a value
  of type `T`;
* `writejson(filename, x)` and `tojson(x)` to write a value as JSON;
* `fromdict(T, x)` and `todict(x)` to convert from and to parsed JSON values;
* `SchemaValidationError`, the error thrown when a value does not conform to the schema.

### Options

* `root_name`: name of the root type. Defaults to the schema `title`, or else to the file name.
* `module_name`: name of the generated module. Defaults to `root_name * "Types"`.
* `schemas`: other schema files that are referenced by their `$id` URL instead of by a
  relative path (see `examples/generate_examples.jl`).

## How the schema is translated

| JSON Schema | Julia |
|---|---|
| `object` with `properties` | `struct <: AbstractSchemaObject`, with a keyword constructor |
| `allOf` | a single struct with the merged properties; `$ref`s are resolved |
| `enum`, `const` | `struct <: AbstractSchemaEnum` wrapping the value, with a checking constructor |
| `oneOf`, `anyOf`, `"type": [...]` | `Union{...}`; when reading, the first option that validates is used |
| `array` | `Vector{T}` |
| `object` without `properties` | `Dict{String, T}` (`T` from `additionalProperties`, or `Any`) |
| `string`, `number`, `integer`, `boolean`, `null` | `String`, `Float64`, `Int64`, `Bool`, `Nothing` |
| optional property, or `null` allowed | `Union{Nothing, T}`; optional fields default to `nothing` and are omitted when writing |
| `additionalProperties` not `false` | unknown properties are kept in the `_extra::Dict{String, Any}` field, so nothing is lost when a document is read and written back |
| `additionalProperties: false` | unknown properties are an error |

Type names come from the definition names, for example `#/definitions/VolumeType` becomes
`VolumeType`. Inline subschemas are named after their `title` if they have one. Otherwise
the name is built from the parent type and the property name, for example
`RecipeTypeType` for the inline `enum` of the `type` property of `RecipeType`. Property
names that are not valid Julia identifiers, or are keywords, are changed (`first-name` →
`first_name`, `end` → `end_`). Each field keeps a link to its original JSON name.

Types are emitted in dependency order. When a schema is recursive, the fields that close
the cycle are declared as `Any`, but they are still converted and checked by the
constructor.

These keywords are checked at construction time: `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`, `pattern`,
`minItems`, `maxItems`, `uniqueItems` (also for array items), `minProperties`,
`maxProperties` and `required`.

### Current limitations

* `not`, `if`/`then`/`else`, `patternProperties`, `dependencies`/`dependentRequired`,
  tuple-style `items`, and `format` are not enforced. String formats such as `date-time`
  are kept as `String`.
* For `oneOf`, the first matching option is used; exclusivity is not checked.
* Remote `$ref`s are not downloaded; give the files locally (relative paths or `schemas`).
* `$id`-relative resolution of nested `$id`s and `$anchor`s is not supported; references
  must be relative file paths or JSON pointers, or match the `$id` of a loaded file.

## Examples

`examples/generate_examples.jl` regenerates the modules in `examples/generated/` from the
schemas in `examples/`:

* `acme_schemas/`: the examples from
  [Getting Started Step-By-Step](https://json-schema.org/learn/getting-started-step-by-step),
  from the [JSON Schema organization](https://json-schema.org), under the
  [BSD license](https://en.wikipedia.org/wiki/BSD_licenses) (as well as the
  [AFL - Academic Free License](https://opensource.org/licenses/AFL-3.0)); see
  [json-schema-org/json-schema-org.github.io](https://github.com/json-schema-org/json-schema-org.github.io);
* `more_schemas/`: examples with references to other files, `enum`, `oneOf`, `anyOf`,
  `allOf` and `not`;
* `beerjson-1.0.1/`: the [BeerJSON](https://github.com/beerjson/beerjson) 1.0.1 schema
  (MIT License). The generated module is `examples/generated/BeerJSON.jl`.

## Tests

```julia
julia> using Pkg; Pkg.test("JSONSchema2Types")
```

The tests include generating the BeerJSON types and checking that every one of the
official BeerJSON 1.0.1 sample documents (in `test/beerjson-1.0.1-samples`) can be read and
written back without changes.

## License

This is licensed under the [MIT License](https://opensource.org/licenses/MIT); see [LICENSE](LICENSE).
