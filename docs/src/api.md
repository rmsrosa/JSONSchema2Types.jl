# API

## JSONSchema2Types

```@docs
JSONSchema2Types
generate_module
```

## Generated modules

Every generated module defines the types of the schema, `RootType` (the type of the root of
the schema), and the following functions and types. They are documented in the generated
code, so in the REPL, `?readjson` shows their documentation once the module is loaded.

| Name | Description |
|---|---|
| `readjson(T, filename)` | read the JSON file `filename` into a value of type `T` |
| `fromjson(T, json)` | parse the JSON string `json` into a value of type `T` |
| `writejson(filename, x; pretty = true, validate)` | write `x` as JSON to the file `filename` (validated first when the checks are off) |
| `tojson(x; pretty = false, validate)` | convert `x` into a JSON string (validated first when the checks are off) |
| `fromdict(T, x)` | convert a parsed JSON value into a value of type `T` |
| `todict(x)` | convert `x` into a JSON-compatible value |
| `setfields(x; kwargs...)` | a copy of the struct `x` with some fields changed, validated |
| `check_formats!(flag)` | turn the validation of the `format` keyword off or on |
| `checks!(flag)` | turn the checks of the constraints off or on; returns the previous setting |
| `with_checks(f, flag)` | call `f()` with the checks of the constraints off or on |
| `validate(x)` | check `x` and the values nested in it; throw a `SchemaValidationError` listing the problems |
| `violations(x)` | the problems found in `x` and the values nested in it, with their locations |
| `isvalid(x)` | whether `x` and the values nested in it conform to the schema |
| `AbstractSchemaObject` | supertype of the generated structs |
| `AbstractSchemaEnum` | supertype of the generated enum types; the value is in the field `value` |
| `SchemaValidationError` | error thrown when a value does not conform to the schema |
