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
| `writejson(filename, x; pretty = true)` | write `x` as JSON to the file `filename` |
| `tojson(x; pretty = false)` | convert `x` into a JSON string |
| `fromdict(T, x)` | convert a parsed JSON value into a value of type `T` |
| `todict(x)` | convert `x` into a JSON-compatible value |
| `check_formats!(flag)` | turn the validation of the `format` keyword off or on |
| `AbstractSchemaObject` | supertype of the generated structs |
| `AbstractSchemaEnum` | supertype of the generated enum types; the value is in the field `value` |
| `SchemaValidationError` | error thrown when a value does not conform to the schema |
