# Generated code

This page explains the code that [`generate_module`](@ref) writes, using the BeerJSON
types as an example. Knowing it is not needed to use the generated types, but helps to read
the generated files, which contain calls to a few internal functions: `_jsfrom`,
`_jscheck`, `_jsto`, and the metadata in `_SPECS`.

```@setup gen
using JSONSchema2Types
const ROOT = pkgdir(JSONSchema2Types)
dir = joinpath(mktempdir(), "BeerJSONTypes")
main = generate_module(joinpath(ROOT, "examples", "beerjson-1.0.1", "json", "beer.json"), dir;
                       root_name = "BeerJSON", split = true)
include(main)
using .BeerJSONTypes
# print the code of the definition of a type, from its docstring to its metadata
function show_definition(file, name)
    code = read(joinpath(dir, file), String)
    i = first(findfirst("\"\"\"\n    $name(", code))
    k = first(findfirst("_SPECS[$name] = ", code))
    j = findnext('\n', code, k) - 1
    print(code[i:j])
end
```

## A generated struct

The schema of a volume, in `measureable_units.json`, is

```json
"VolumeType": {
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "unit": { "$ref": "#/definitions/VolumeUnitType" },
    "value": { "type": "number" }
  },
  "required": ["unit", "value"]
}
```

and this is the code generated for it:

```@example gen
show_definition("measureable_units.jl", "VolumeType")
```

It has four parts:

1. **A docstring**, from the descriptions in the schema, listing the fields with their
   types and whether they are required.
2. **The struct**, a subtype of `AbstractSchemaObject`, with one field per property.
   Optional properties have the type `Union{Nothing, T}`.
3. **An inner keyword constructor**, the only way to create a value of the type. Each
   argument is passed through **`_jsfrom`** with the type of its field, which converts
   and validates it. Then **`_jscheck`** checks the constraints of the schema on the
   converted values, and `new` creates the value. Optional arguments default to `nothing`.
4. **The metadata `_SPEC_VolumeType`**: the JSON name of each field (which may differ
   from the Julia name, e.g. for `first-name` or `end`), whether it is required, its
   constraints, and more, used for reading, writing and checking. It is a constant, returned
   by `_specs(VolumeType)`, so that the checks are type stable and compiled for each type
   (and also registered in the dictionary `_SPECS`, by type).

## `_jsfrom`: from JSON to Julia

`_jsfrom(T, x)` converts `x` into a value of type `T`, and throws a
`SchemaValidationError` if it cannot. The name stands for "from JSON". `x` can be a
parsed JSON value, or a plain Julia one (a `Dict` or a named tuple for an object, a vector
for an array, a string, a number...), or already a value of type `T`:

```@example gen
BeerJSONTypes._jsfrom(Float64, 20)
```

```@example gen
BeerJSONTypes._jsfrom(VolumeUnitType, "l")
```

```@example gen
BeerJSONTypes._jsfrom(VolumeType, Dict("unit" => "l", "value" => 20))
```

```@example gen
BeerJSONTypes._jsfrom(Union{VolumeType, MassType}, (unit = "kg", value = 2))
```

```@example gen
try
    BeerJSONTypes._jsfrom(Int64, 2.5)
catch err
    showerror(stdout, err)
end
```

The conversion is recursive. For a generated struct, `_jsfrom` calls its keyword
constructor with the properties of the dict, whose arguments go through `_jsfrom` in turn,
and so on. For a `Union`, which comes from `oneOf`, `anyOf` or an optional field, the
options are tried in turn.

So constructing a value and reading a document are the same thing. `VolumeType(unit = "l",
value = 20)` converts `"l"` with `_jsfrom(VolumeUnitType, "l")` and `20` with
`_jsfrom(Float64, 20)`. Reading a document is `_jsfrom(RootType, JSON.parse(text))`, which
is what `fromjson` does. Either way, the result is valid.

## `_jscheck` and `_SPECS`: the constraints

The types enforce much of the schema by themselves: the type of each property, the
required ones, enums. The rest is checked by `_jscheck`, using the metadata in `_SPECS`:
the constraints of each field (`minimum`, `pattern`, `minItems`...), and the keywords that
cannot be expressed by types at all (`not`, `if`/`then`/`else`, the exclusivity of `oneOf`,
`format`...). The generator embeds these as subschemas in `_SPECS`, written as JSON, and
`_jscheck` validates the JSON form of the values against them with a small JSON Schema
validator, `_jsvalid`. For instance, the amount of a hop addition is a volume or a mass,
exactly one of them:

```@example gen
show_definition("hop.jl", "HopAdditionType")
```

The validator can be called directly, with a schema and a value as parsed JSON:

```@example gen
schema = Dict("type" => "string", "not" => Dict("enum" => ["password", "123456"]))
BeerJSONTypes._jsvalid(schema, "123456")
```

## `_jsto`: from Julia to JSON

`_jsto(x)` is the inverse of `_jsfrom` ("to JSON"). It converts a value into
JSON-compatible values: structs become objects with the original JSON property names
(leaving out optional fields that are `nothing`), enums become their values, vectors and
tuples become arrays:

```@example gen
v = VolumeType(unit = "l", value = 20)
BeerJSONTypes._jsto(v)
```

`todict` is `_jsto`, and `tojson` and `writejson` serialize its result with JSON.jl.

## Enum types

An `enum` becomes a type wrapping the value, whose constructor checks it against the
allowed values, recorded in `_SPECS`:

```@example gen
show_definition("measureable_units.jl", "VolumeUnitType")
```

## The runtime code

All of these functions are defined in the generated module itself, in `runtime.jl` (or at
the top of the file, for a single-file module), so a generated module does not depend on
JSONSchema2Types.jl. The runtime code is the same for every generated module. Its
functions are internal (their names start with `_js`), except for those listed in the
[API](@ref), which are exported.
