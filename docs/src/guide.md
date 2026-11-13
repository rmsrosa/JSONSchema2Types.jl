# Guide

## Generating a module

[`generate_module`](@ref) reads a schema, and every schema file it references with `$ref`,
and writes a module:

```julia
generate_module(schema_file, output;
    root_name = nothing,   # name of the root type; defaults to the schema `title` or file name
    module_name = nothing, # defaults to `root_name * "Types"`
    split = false,         # write a directory with one file per schema file
    schemas = String[],    # other schema files, referenced by their `$id`
    type_names = Dict(),   # names chosen for some types
)
```

The generated module only needs JSON.jl. It exports the generated types and:

| Function | Purpose |
|---|---|
| `readjson(T, filename)`, `fromjson(T, string)` | read a JSON document into a value of type `T`, validating it |
| `writejson(filename, x)`, `tojson(x)` | write a value as JSON |
| `fromdict(T, x)`, `todict(x)` | convert from and to parsed JSON values (`Dict`s, vectors, numbers...) |
| `RootType` | alias for the type of the root of the schema |
| `SchemaValidationError` | error thrown when a value does not conform to the schema |
| `check_formats!(flag)` | turn the validation of `format` off or on |

## How a schema is translated

| JSON Schema | Julia |
|---|---|
| `object` with `properties` | `struct <: AbstractSchemaObject`, with a keyword constructor |
| `allOf` | a single struct with the merged properties; `$ref`s are resolved |
| `enum`, `const` | `struct <: AbstractSchemaEnum` wrapping the value, with a checking constructor |
| `oneOf`, `anyOf`, `"type": [...]` | `Union{...}` |
| `array` | `Vector{T}` |
| `object` without `properties` | `Dict{String, T}` (`T` from `additionalProperties`, or `Any`) |
| `string`, `number`, `integer`, `boolean`, `null` | `String`, `Float64`, `Int64`, `Bool`, `Nothing` |
| optional property, or `null` allowed | `Union{Nothing, T}`; optional fields default to `nothing` and are omitted when writing |
| `additionalProperties` not `false` | unknown properties are kept in the `_extra` field, so nothing is lost when a document is read and written back |
| `additionalProperties: false`, `unevaluatedProperties: false` | unknown properties are an error |
| `patternProperties` | matching properties are kept (in `_extra` for a struct) and checked against their schemas |
| `format` | the value stays a `String`; well-known formats are checked |
| `deprecated: true` | flagged in the docstrings |

The keyword constructors convert plain values, so `VolumeType(unit = "l", value = 20)`
works as well as `VolumeType(unit = VolumeUnitType("l"), value = 20.0)`, and nested objects
can be given as `Dict`s or named tuples: `HopAdditionType(..., amount = (unit = "g", value = 50))`. Reading a document
goes through the same constructors, so a value read from a file is always valid.

Types are written in dependency order. When a schema is recursive, the fields that close a
cycle are declared as `Any`, but they are still converted and checked by the constructor.

## Validation

Most of a schema is enforced by the types themselves: the type of each field, required
properties, enums, and the constraints `minimum`, `maximum`, `exclusiveMinimum`,
`exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`, `pattern`, `minItems`,
`maxItems`, `uniqueItems`, `minProperties` and `maxProperties`.

The keywords that cannot be expressed by Julia types are checked at runtime. The
generator embeds the corresponding subschemas in the generated code, and a small JSON
Schema validator checks the JSON form of the values against them:

* `not`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas`, `dependencies`,
  `propertyNames`, `contains`, `prefixItems` and `patternProperties`;
* `oneOf` and `anyOf`: reading picks the first option of the `Union` whose type fits, and
  the runtime check makes sure that the value satisfies the full schema of an option and,
  for `oneOf`, that it matches *exactly one* option;
* `format`: `date-time`, `date`, `time`, `email`, `uri`, `uuid`, `ipv4`, `ipv6`, `hostname`
  and `regex` are checked; other formats are ignored. JSON Schema treats `format` as an
  annotation by default, so these checks can be turned off with `check_formats!(false)`.

A value that does not conform throws a `SchemaValidationError` that says where and why.

## Type names

Type names come from the definition names: `#/definitions/VolumeType` (or
`#/$defs/VolumeType`) becomes `VolumeType`. Inline subschemas are named after their
`title`, if they have one. Otherwise the name is built from the parent type, without a
trailing `Type` or `Base`, and the property name:

* inline enums get an `Enum` suffix: the `type` of `RecipeType` is `RecipeTypeEnum`, the
  `form` of `HopVarietyBase` is `HopVarietyFormEnum`;
* a property with the same name as its parent gets `Content`: `beerjson` in `BeerJSON` is
  `BeerJSONContent`;
* options of `oneOf`/`anyOf` get `Option1`, `Option2`..., array items get `Item`.

Any type can be given another name with `type_names`, which maps the location of its
subschema, `"file.json#/json/pointer"` (or `"#/json/pointer"` in the root schema file), to
a name:

```julia
generate_module("beer.json", "BeerJSONTypes"; root_name = "BeerJSON",
    type_names = Dict("recipe.json#/definitions/RecipeType/properties/type" => "RecipeKind"))
```

Property names that are not valid Julia identifiers, or are Julia keywords, are changed
(`first-name` becomes `first_name`, `end` becomes `end_`). The fields keep their original
JSON names for reading and writing.

## Splitting into several files

For a schema spread over several files, `split = true` writes a directory with one Julia
file per schema file:

```
BeerJSONTypes/
  BeerJSONTypes.jl        # the module: exports and includes, in dependency order
  runtime.jl              # reading, writing and validation
  measureable_units.jl    # types from measureable_units.json
  hop.jl, recipe.jl, ...
  beer.jl                 # the root type, from beer.json
```

All the files belong to the same module, which is loaded by including the main file. Each
type is in the file of the schema file that defines it, and inline subschemas go with the
type containing them. Schema files whose types depend on each other in a cycle share a
single file.

## References

`$ref`s are resolved relative to the file containing them, as JSON pointers (both
`definitions` and `$defs`), or by the `$id` of the loaded schemas. Schema files that are
only referenced by their `$id` URL can be given in `schemas`. Remote schemas are not
downloaded.

## Limitations

* Values with a `format` stay `String`s; e.g. `date-time` is not converted to `DateTime`.
* `unevaluatedProperties` and `unevaluatedItems` inside subschemas checked at runtime (in
  `not` or `if`, say) only take into account the keywords of their own subschema.
* Tuple-style arrays (`prefixItems`) are `Vector{Any}`, with their items checked at runtime.
* `$anchor`s and nested `$id`s are not supported.
