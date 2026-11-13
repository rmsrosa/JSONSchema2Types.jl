# JSONSchema2Types

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://rmsrosa.github.io/JSONSchema2Types.jl/dev/)
[![CI](https://github.com/rmsrosa/JSONSchema2Types.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/rmsrosa/JSONSchema2Types.jl/actions/workflows/CI.yml)

Generate Julia types from a [JSON Schema](https://json-schema.org), together with functions
to read and write JSON documents that conform to the schema.

The main motivation is the [BeerJSON](https://github.com/beerjson/beerjson) schema, which is
large and intricate, so writing the types by hand would take a lot of work. The package is
general, though, and should be useful for other schemas as well.

## Usage

```julia
julia> using JSONSchema2Types

julia> generate_module("examples/beerjson-1.0.1/json/beer.json", "BeerJSONTypes";
           root_name = "BeerJSON", split = true)
"BeerJSONTypes/BeerJSONTypes.jl"
```

This reads the schema, and every schema file it references with `$ref`. It then writes a
self-contained module, `BeerJSONTypes`, which depends only on
[JSON.jl](https://github.com/JuliaIO/JSON.jl). With `split = true`, the module is written
to a directory, with one file per schema file (see [below](#splitting-into-several-files)):

```julia
julia> include("BeerJSONTypes/BeerJSONTypes.jl"); using .BeerJSONTypes

julia> doc = readjson(RootType, "test/beerjson-1.0.1-samples/real/SourMash.json");

julia> recipe = doc.beerjson.recipes[1];

julia> recipe.name, recipe.type
("Sour Mash", RecipeTypeEnum("all grain"))

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
* `SchemaValidationError`, the error thrown when a value does not conform to the schema;
* `check_formats!(flag)` to turn the validation of `format` off or on (see below).

### Options

* `root_name`: name of the root type. Defaults to the schema `title`, or else to the file name.
* `module_name`: name of the generated module. Defaults to `root_name * "Types"`. It
  must differ from the names of the generated types.
* `split`: write the module to the directory `output`, split into several files (see
  below), instead of to the single file `output`. Defaults to `false`.
* `schemas`: other schema files that are referenced by their `$id` URL instead of by a
  relative path (see `examples/generate_examples.jl`).
* `type_names`: names to use for chosen types, instead of the derived ones (see
  [Type names](#type-names)).

### Splitting into several files

For a schema spread over several files, like BeerJSON, `split = true` writes one Julia file
per schema file, so the generated code follows the organization of the schema:

```
BeerJSONTypes/
  BeerJSONTypes.jl        # the module: exports and `include`s, in dependency order
  runtime.jl              # reading, writing and validation
  measureable_units.jl    # types from measureable_units.json
  timing.jl               # types from timing.json
  hop.jl, recipe.jl, ...  # and so on
  beer.jl                 # the root type, from beer.json
```

All the files are part of the same module, so the types are used just as in the
single-file version. Inline subschemas go in the file of the type that contains them.
The files are included so that every file only uses types from itself and from the files
before it. Schema files whose types depend on each other in a cycle share a single file
(e.g. `author_and_book.jl`).

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
| `unevaluatedProperties` (2019-09 and later) | same as `additionalProperties`, applied after merging `allOf`, so `unevaluatedProperties: false` closes an `allOf`-composed type |
| `deprecated: true` | flagged as deprecated in the docstrings of the field or type |
| `patternProperties` | in a struct, matching properties are kept in `_extra`; in a dict, values are kept as they are; either way they are checked against their schemas |
| `not`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas`, `dependencies`, `propertyNames`, `contains`, `prefixItems` | checked at runtime (see below) |
| `format` | the value stays a `String`; well-known formats are checked at runtime (see below) |

### Checks at runtime

Most of a schema is enforced by the types themselves. The keywords that cannot be
expressed by Julia types are checked when a value is constructed or read. The generator
embeds the corresponding subschemas, with their `$ref`s resolved, in the generated code,
and a small JSON Schema validator in the runtime checks the JSON form of the value against
them. These keywords are:

* `not`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas`, `dependencies`,
  `propertyNames`, `contains`/`minContains`/`maxContains`, `prefixItems` and
  `patternProperties`;
* `oneOf` and `anyOf`. A field from `oneOf` or `anyOf` is a `Union`, and reading a value
  picks the first option whose type fits. The runtime check then makes sure that the value
  satisfies the full schema of an option (including its constraints) and, for `oneOf`,
  that it matches *exactly one* option;
* `format`: `date-time`, `date`, `time`, `email`, `uri`, `uuid`, `ipv4`, `ipv6`, `hostname`
  and `regex` are checked; other formats are ignored. JSON Schema treats `format` as an
  annotation by default, so the checks can be turned off with `check_formats!(false)` (and
  back on with `check_formats!(true)`).

### Type names

Type names come from the definition names, for example `#/definitions/VolumeType` becomes
`VolumeType`. Inline subschemas are named after their `title` if they have one. Otherwise
the name is built from the parent type, without a trailing `Type` or `Base`, and the
property name. Inline enums get an `Enum` suffix. For example, the inline `enum` of the
`type` property of `RecipeType` is `RecipeTypeEnum`, and that of `form` in `HopVarietyBase`
is `HopVarietyFormEnum`. A property with the same name as its parent gets `Content`, e.g.
`beerjson` in `BeerJSON` is `BeerJSONContent`.

Any type can be given another name with `type_names`, which maps the location of its
subschema, as `"file.json#/json/pointer"` (or `"#/json/pointer"` in the root schema file),
to a name:

```julia
generate_module("beer.json", "BeerJSONTypes"; root_name = "BeerJSON", split = true,
    type_names = Dict("recipe.json#/definitions/RecipeType/properties/type" => "RecipeKind",
                      "#/properties/beerjson" => "BeerJSONDocument"))
```

Property names that are not valid Julia identifiers, or are keywords, are changed
(`first-name` → `first_name`, `end` → `end_`). Each field keeps a link to its original
JSON name.

Types are emitted in dependency order. When a schema is recursive, the fields that close
the cycle are declared as `Any`, but they are still converted and checked by the
constructor.

These keywords are checked at construction time: `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`, `pattern`,
`minItems`, `maxItems`, `uniqueItems` (also for array items), `minProperties`,
`maxProperties` and `required`.

### Current limitations

* Values with a `format` stay `String`s; e.g. `date-time` is not converted to `DateTime`.
* `unevaluatedProperties` and `unevaluatedItems` inside the subschemas checked at runtime
  (e.g. in `not` or `if`) only take into account the keywords of their own subschema, not
  those of `allOf`/`$ref` siblings. At the level of a generated type they are exact.
* Tuple-style arrays (`prefixItems`, or `items` as a list) are `Vector{Any}`, with their
  items checked at runtime.
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
  (MIT License). The generated module, split into one file per schema file, is in
  `examples/generated/BeerJSONTypes/`.

## Documentation

The [documentation](https://rmsrosa.github.io/JSONSchema2Types.jl/dev/) has a guide, the
examples step by step, and a page reading and displaying BeerJSON recipes, styles, water
profiles and hop varieties with the generated types. To build it locally:

```shell
julia --project=docs -e 'using Pkg; Pkg.develop(path = "."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

The pages are written to `docs/build/`.

## Tests

```julia
julia> using Pkg; Pkg.test("JSONSchema2Types")
```

The tests include generating the BeerJSON types and checking that every one of the
official BeerJSON 1.0.1 sample documents (in `test/beerjson-1.0.1-samples`) can be read and
written back without changes.

## License

This is licensed under the [MIT License](https://opensource.org/licenses/MIT); see [LICENSE](LICENSE).
