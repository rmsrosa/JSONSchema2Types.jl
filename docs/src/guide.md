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
    download = false,      # fetch remote schemas referenced by `$ref`
    typed_formats = false, # store `date`, `date-time` and `uuid` strings as Julia types
    use_defaults = false,  # optional fields default to the schema `default`, not `nothing`
)
```

The generated module only needs JSON.jl. It exports the generated types and:

| Function | Purpose |
|---|---|
| `readjson(T, filename)`, `fromjson(T, string)` | read a JSON document into a value of type `T`, validating it |
| `writejson(filename, x)`, `tojson(x)` | write a value as JSON |
| `setfields(x; kwargs...)` | a copy of `x` with some fields changed, validated |
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
| `prefixItems` (or `items` as a list), all required | `Tuple{A, B}`, or `Tuple{A, B, Vararg{T}}` when more items are allowed |
| `object` without `properties` | `Dict{String, T}` (`T` from `additionalProperties`, or `Any`) |
| `string`, `boolean`, `null` | `String`, `Bool`, `Nothing` |
| `integer`, `number` | the type parameters `I <: Integer` and `T <: Real` of the structs; `Int64` and `Float64` by default (see [Numeric types](@ref)) |
| optional property, or `null` allowed | `Union{Nothing, T}`; optional fields default to `nothing` and are omitted when writing |
| `additionalProperties` not `false` | unknown properties are kept in the `_extra` field, so nothing is lost when a document is read and written back |
| `additionalProperties: false`, `unevaluatedProperties: false` | unknown properties are an error |
| `patternProperties` | matching properties are kept (in `_extra` for a struct) and checked against their schemas |
| `format` | the value stays a `String`; well-known formats are checked. With `typed_formats = true`, `date`, `date-time` and `uuid` become `Dates.Date`, `Dates.DateTime` and `UUIDs.UUID` |
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
* `format`: `date-time`, `date`, `time`, `duration`, `email`, `idn-email`,
  `hostname`, `idn-hostname`, `ipv4`, `ipv6`, `uri`, `uri-reference`, `iri`, `iri-reference`,
  `uri-template`, `json-pointer`, `relative-json-pointer`, `uuid` and `regex` are checked
  (`idn-hostname` loosely: the IDNA2008 rules are not), and other formats are ignored. JSON Schema treats `format` as an
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

## Tuples

An array described by `prefixItems` (or, before 2020-12, by `items` as a list) is a tuple
when all its prefix items are required (`minItems` at least their number), since a Julia
tuple cannot have optional elements:

| Schema | Julia |
|---|---|
| `"prefixItems": [{"type": "number"}, {"type": "number"}], "items": false, "minItems": 2` | `Tuple{Float64, Float64}` |
| `"prefixItems": [{"type": "string"}], "items": {"type": "integer"}, "minItems": 1` | `Tuple{String, Vararg{Int64}}` |
| `"prefixItems": [{"type": "string"}], "minItems": 1` | `Tuple{String, Vararg{Any}}` |
| `"prefixItems": [{"type": "string"}, {"type": "integer"}]` (no `minItems`) | `Vector{Any}`, with the items checked at runtime |

Tuples are written as JSON arrays.

## Numeric types

JSON Schema has two numeric types, `integer` and `number`, with no limit on their size or
precision. The generated structs leave the choice of the Julia types to their users: each
struct has two type parameters, `I <: Integer` for the integers and `T <: Real` for the
other numbers (`VolumeType{I, T}`), and passes them on to the structs it contains.
Without them, the defaults are `Int64` and `Float64`:

```julia
VolumeType(unit = "l", value = 20)                    # VolumeType{Int64, Float64}
VolumeType{Int, BigFloat}(unit = "l", value = 20)     # values as BigFloat
readjson(BeerJSON{BigInt, BigFloat}, "recipe.json")   # all the numbers in the document
VolumeType{Int, Rational{Int}}(unit = "l", value = 0.5).value   # 1//2
```

The names `I` and `T` are reserved: a property named `I` or `T` becomes the field `I_` or
`T_`, and a definition named `I` or `T` gets another type name.

Any `Integer` and `Real` types can be used: `Int32`, `Int128`, `BigInt`; `Float32`,
`BigFloat`, rationals, or types from other packages that convert from numbers. Values that
cannot be represented in the chosen type (e.g. an integer too large for `Int64`) are
rejected with a `SchemaValidationError`.

When reading a document with a floating-point type other than `Float64`, its numbers are
parsed with full precision (as `BigFloat` at the current precision, see
`setprecision`), not through `Float64`. Writing a document writes the numbers as they are
stored: note that a decimal number such as `1.1` has no exact binary representation, so a
`BigFloat` writes all the digits of its precision.

`RootType` is the root type with the default numeric types. Printed values show the
numeric types only when they are not the default ones, e.g.
`VolumeType{Int64, BigFloat}(VolumeUnitType("l"), 20.0)`.

## Changing values

The generated structs are immutable. `setfields(x; field = value, ...)` returns a copy of
`x` with some fields replaced; the new values are converted and validated as by the
constructor, so plain values can be given:

```julia
v = VolumeType(unit = "l", value = 20)
setfields(v; value = 40)            # VolumeType(VolumeUnitType("l"), 40.0)
setfields(v; unit = "litre")        # SchemaValidationError
```

Each struct also has a positional constructor, with its fields in order, so values can be
written as they are printed (`VolumeType(VolumeUnitType("l"), 20.0)`). This is also what
[Accessors.jl](https://github.com/JuliaObjects/Accessors.jl) uses, so its `@set` works on
the generated types, for changes deep inside a document, without further setup:

```julia
using Accessors
recipe2 = @set recipe.ingredients.hop_additions[1].amount.value = 0.05
```

## Default values

By default, an optional property that is missing is `nothing`. With `use_defaults = true`,
optional properties with a `default` in the schema (or in the schema their `\$ref` points
to) default to it instead, both in the keyword constructors and when reading a document.
Since the default values are then written out, a document missing them is not written back
unchanged: that is why this is not the default.

## Dates and UUIDs

With `typed_formats = true`, strings with these formats are stored as Julia values:

| `format` | Julia | Written back as |
|---|---|---|
| `date` | `Dates.Date` | `2026-11-15` |
| `date-time` | `Dates.DateTime`, in UTC, with millisecond precision | `2026-11-15T08:30:00.250Z` |
| `uuid` | `UUIDs.UUID` | lowercase |

A date-time with a UTC offset, such as `2026-11-15T10:30:00+02:00`, is converted to UTC, so
it is written back as the same instant in a different notation. Likewise, a UUID in
uppercase is written back in lowercase. That is why this is not the default. `time` stays a
`String`, since `Dates.Time` has no UTC offset. The generated module then imports the
`Dates` and `UUIDs` standard libraries, which must be available where it is loaded (in a
package, add them to its dependencies).

## References

`$ref`s are resolved as URIs, against the base URI at their location, which is set by the
`$id` of the enclosing (sub)schemas, as JSON Schema specifies. They can point to:

* a location in the same or another file, by a JSON pointer (`#/$defs/Address`, or
  `common.json#/definitions/Address`), with `definitions` or `$defs`;
* a schema or subschema by its `$id`, including nested `$id`s (embedded resources), within
  which `#/...` pointers are relative to that resource;
* a subschema with an `$anchor` (`#name`), or an `"$id": "#name"` in earlier drafts;
* a file, by a path relative to the file containing the reference. This also works for local
  copies of schemas whose `$id`s are remote URLs, as BeerJSON's are.

Schema files that are only referenced by their `$id` URL can be given in `schemas`. Remote
schemas are not downloaded unless `download = true`, which fetches them with Downloads.jl.
`download` can also be a function, called with the URL and returning the content of the
schema, e.g. to use a cache.

## Limitations

See also [Conformance](@ref) for the results of the official JSON Schema Test Suite.

* A schema with `properties` but no `type` is a struct, so it only accepts objects.
* `$dynamicRef`/`$dynamicAnchor` are resolved statically, like `$ref`/`$anchor`; `$recursiveRef`
  (2019-09) is not supported.
* Arrays with optional prefix items are `Vector{Any}`, with their items checked at runtime.
* `time` strings are not converted to Julia values, even with `typed_formats = true`.
* Integers are `Int64` and numbers `Float64`.
