# JSONSchema2Types

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://rmsrosa.github.io/JSONSchema2Types.jl/dev/)
[![CI](https://github.com/rmsrosa/JSONSchema2Types.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/rmsrosa/JSONSchema2Types.jl/actions/workflows/CI.yml)

Generate Julia types from a [JSON Schema](https://json-schema.org), together with functions
to read and write JSON documents that conform to the schema.

The main motivation is the [BeerJSON](https://github.com/beerjson/beerjson) schema, which is
large and intricate, so writing the types by hand would take a lot of work. The package is
general, though, and should be useful for other schemas as well.

## Installation

The package is not registered yet. Install it from GitHub:

```julia
julia> using Pkg

julia> Pkg.add(url = "https://github.com/rmsrosa/JSONSchema2Types.jl")
```

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
* `setfields(x; kwargs...)`, a copy of a value with some fields changed (the structs also
  work with Accessors.jl's `@set`);
* `SchemaValidationError`, the error thrown when a value does not conform to the schema;
* `check_formats!(flag)` to turn the validation of `format` off or on (see below);
* `checks!(flag)` and `with_checks(f, flag)` to turn the checks of the constraints off or
  on, and `validate(x)`, `violations(x)` and `isvalid(x)` to check a value later (see
  [Turning the checks off](#turning-the-checks-off)).

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
* `download`: fetch remote schemas referenced by `$ref` (with Downloads.jl), or a
  function `url -> content`. Defaults to `false`.
* `typed_formats`: store strings with the formats `date`, `date-time` and `uuid` as
  `Dates.Date`, `Dates.DateTime` (UTC) and `UUIDs.UUID`. Defaults to `false`, since these
  values are written back in a normalized form.
* `use_defaults`: optional fields default to the `default` of their schema, instead of
  `nothing`. Defaults to `false`, since the defaults are then written out.
* `checks`: whether the checks of the constraints are on when the module is loaded.
  Defaults to `true` (see [Turning the checks off](#turning-the-checks-off)).
* `validation`: `:inline` (the default), the constructors check the constraints of the
  schema; `:separate`, minimal types whose constructors do not, with the checks in a
  separate, optional file; `:none`, minimal types without any checks (see
  [Minimal types](#minimal-types-with-the-validation-in-a-separate-file)).

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
| `prefixItems` (or `items` as a list), all required | `Tuple{A, B}`, or `Tuple{A, B, Vararg{T}}` when more items are allowed |
| `object` without `properties` | `Dict{String, T}` (`T` from `additionalProperties`, or `Any`) |
| `string`, `boolean`, `null` | `String`, `Bool`, `Nothing` |
| `integer`, `number` | the type parameters `I <: Integer` and `T <: Real` of the structs (`Int64`, `Float64` by default) |
| optional property, or `null` allowed | `Union{Nothing, T}`; optional fields default to `nothing` and are omitted when writing |
| `additionalProperties` not `false` | unknown properties are kept in the `_extra::Dict{String, Any}` field, so nothing is lost when a document is read and written back |
| `additionalProperties: false` | unknown properties are an error |
| `unevaluatedProperties` (2019-09 and later) | same as `additionalProperties`, applied after merging `allOf`, so `unevaluatedProperties: false` closes an `allOf`-composed type |
| `deprecated: true` | flagged as deprecated in the docstrings of the field or type |
| `patternProperties` | in a struct, matching properties are kept in `_extra`; in a dict, values are kept as they are; either way they are checked against their schemas |
| `not`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas`, `dependencies`, `propertyNames`, `contains`, `prefixItems` | checked at runtime (see below) |
| `format` | the value stays a `String`; well-known formats are checked at runtime (see below). With `typed_formats = true`, `date`, `date-time` and `uuid` become `Dates.Date`, `Dates.DateTime` and `UUIDs.UUID` |

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
* `format`: `date-time`, `date`, `time`, `duration`, `email`, `idn-email`,
  `hostname`, `idn-hostname`, `ipv4`, `ipv6`, `uri`, `uri-reference`, `iri`, `iri-reference`,
  `uri-template`, `json-pointer`, `relative-json-pointer`, `uuid` and `regex` are checked
  (`idn-hostname` loosely: the IDNA2008 rules are not), and other formats are ignored. JSON Schema treats `format` as an
  annotation by default, so the checks can be turned off with `check_formats!(false)` (and
  back on with `check_formats!(true)`).

### Turning the checks off

For speed, the checks of the constraints of the schema can be turned off with
`checks!(false)`, or only for some code with `with_checks(false) do ... end` (or in the
generated module from the start, with `generate_module(...; checks = false)`). Values are
then only converted to the types of their fields, which still enforce the structure of
the schema (the types of the properties, required properties, enumeration types), but not
its constraints (`minimum`, `pattern`, the values of enumerations, `oneOf`...). A value
read into a union of generated types is still checked, to choose its type.

Values can be checked later, e.g. after processing them, with `validate(x)`, which throws a
`SchemaValidationError` listing the problems found in `x` and the values nested in it, with
their locations (`violations(x)` returns them, and `isvalid(x)` says whether there are
none). With the checks off, `tojson` and `writejson` validate before writing (or not, with
`validate = false`):

```julia
checks!(false)
recipe2 = setfields(recipe; batch_size = (unit = "litre", value = 20))   # not checked
violations(recipe2)   # ["batch_size.unit: invalid value \"litre\" for `VolumeUnitType`; ..."]
writejson("recipe.json", recipe2)                                       # SchemaValidationError
```

### Minimal types, with the validation in a separate file

With `validation = :separate`, the generated types are minimal: the same structs, with the
same constructors, which convert the values to the types of their fields but do not check
the constraints of the schema. Everything needed to check them (the constraints of each
type, the subschemas checked at runtime and the validator) goes in a separate file,
`validation.jl` (or `<name>_validation.jl` next to the module file, without `split`), which
the module includes only if it is present:

```julia
isfile(joinpath(@__DIR__, "validation.jl")) && include("validation.jl")
```

Without that file, the module only reads and writes. With it, it also has `validate(x)`,
`violations(x)` and `isvalid(x)`, and `tojson` and `writejson` validate before writing
(unless given `validate = false`). Reading is not checked: use `validate(readjson(T, file))`
for that. With `validation = :none`, the validation file is not written at all.

The types still enforce the structure of the schema: the types of the properties, required
properties, the properties allowed and the enumeration types. A JSON value read into a
union of generated types (from `oneOf` or `anyOf`) gets the first option that fits by its
properties and the values of its enumerations (e.g. a `unit` that is `"l"` for a volume, `"kg"`
for a mass); options that only differ by other constraints cannot be told apart.

For BeerJSON, the minimal module is 221 KiB of code, instead of 280 KiB, and the
validation file 90 KiB.

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

### References

`$ref`s are resolved as URIs, against the base URI set by the enclosing `$id`s: JSON
pointers (with `definitions` or `$defs`), `$id`s (including nested ones), `$anchor`s, and
paths relative to the schema file. Schemas referenced only by their `$id` URL can be given
in `schemas`, or downloaded with `download = true`.

### Numeric types

The generated structs are parametric in the types of their numbers: `VolumeType{I, T}`,
with `I <: Integer` for the integers and `T <: Real` for the other numbers,
passed on to the structs they contain. They default to `Int64` and `Float64`, and can be
chosen when constructing or reading values, e.g. `readjson(BeerJSON{BigInt, BigFloat}, file)`
(numbers are then parsed with full precision).

### Conformance

The validation is checked against the official
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
(2020-12), end to end, in CI: 2175 of its 2288 tests pass (97% of the core keywords, 93% of
the formats). See the [documentation](https://rmsrosa.github.io/JSONSchema2Types.jl/dev/conformance/)
for the details, and `test/json-schema-test-suite/run.jl` to run it.

### Current limitations

* A schema with `properties` but no `type` is a struct, so it only accepts objects.
* `$dynamicRef`/`$dynamicAnchor` are resolved statically, like `$ref`/`$anchor`; `$recursiveRef`
  (2019-09) is not supported.
* `hostname`/`idn-hostname` do not check the IDNA2008 rules.
* Arrays with optional prefix items are `Vector{Any}`, with their items checked at runtime.
* `time` strings are not converted to Julia values, even with `typed_formats = true`.
* Integers are `Int64` and numbers `Float64`.

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

## Related packages

[JSONSchema.jl](https://github.com/JuliaIO/JSONSchema.jl) and
[CorvusJsonSchema.jl](https://github.com/corvus-dotnet/Corvus.JsonSchema/tree/main/src-jl/CorvusJsonSchema)
validate documents against schemas, without generating types;
[JSONSchemaGenerator.jl](https://github.com/matthijscox/JSONSchemaGenerator.jl) and
[Struct2JSONSchema.jl](https://github.com/abap34/Struct2JSONSchema.jl) go the other way,
from Julia types to schemas. See the
[documentation](https://rmsrosa.github.io/JSONSchema2Types.jl/dev/related/) for a comparison.

## Documentation

The [documentation](https://rmsrosa.github.io/JSONSchema2Types.jl/dev/) has a guide, the
examples step by step, a page reading and displaying BeerJSON recipes, styles, water
profiles and hop varieties with the generated types, and an explanation of the generated
code and of the internal functions it calls (`_jsfrom`, `_jscheck`, `_jsto`). To build it locally:

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

Benchmarks of reading, writing, constructing and modifying the generated types are in
`benchmark/benchmarks.jl` (see the instructions at the top of that file).

## License

This is licensed under the [MIT License](https://opensource.org/licenses/MIT); see [LICENSE](LICENSE).
