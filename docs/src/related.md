# Related packages

JSON Schema and Julia types meet in a few different problems, which different packages
solve:

1. **Validating** JSON documents against a schema, keeping them as dictionaries.
2. **Generating Julia types from a schema** (what JSONSchema2Types.jl does), to read,
   write and build documents as typed values.
3. **Generating a schema from Julia types**: describing existing structs, e.g. for an API
   or for the tools of an LLM agent.
4. **Generating Julia types from sample JSON**, without a schema.
5. **Reading JSON into hand-written Julia types**.

## Packages

### Validators

* [**JSONSchema.jl**](https://github.com/JuliaIO/JSONSchema.jl) (JuliaIO) validates parsed
  JSON documents against a schema with `validate(schema, data)`, which returns `nothing`
  or a report of the first failure, with its location. It supports drafts 4, 6 and 7, and
  is tested with the corresponding parts of the JSON Schema Test Suite. It does not
  implement the newer keywords of 2019-09 and 2020-12 (`unevaluatedProperties`,
  `prefixItems`, `$dynamicRef`...), nor the checks of `format`. Recent versions also
  generate simple schemas from Julia types, with `JSONSchema.schema(T)` (problem 3).
* [**CorvusJsonSchema.jl**](https://github.com/corvus-dotnet/Corvus.JsonSchema/tree/main/src-jl/CorvusJsonSchema)
  is a JSON Schema evaluator ported from the .NET library Corvus.JsonSchema. It supports
  drafts 4, 6, 7, 2019-09 and 2020-12, passes the whole JSON Schema Test Suite (required
  and optional tests, including `$dynamicRef` and the IDN formats) and its annotation tests,
  has no dependencies, and is fast and allocation-free. It validates JSON text or parsed
  documents (`compile_schema`, `isvalid`, `validate`), with detailed results; it does not
  generate types.

### From Julia types to schemas

* **JSONSchema.jl**, with `JSONSchema.schema(T)`: small schemas for named tuples, concrete
  structs, scalars, vectors, dicts, tuples and `Union{Nothing, T}`, inlined (no `$ref`s),
  meant for the parameters of agent tools and APIs.
* [**JSONSchemaGenerator.jl**](https://github.com/matthijscox/JSONSchemaGenerator.jl)
  generates minimal schemas from structs declared with StructTypes.jl, optionally with
  `$ref`s to `$defs`, and with `allOf`/`anyOf`/`oneOf`/`not` through special types. It does
  not support parametric types, nor unions other than `Union{Nothing, T}`.
* [**Struct2JSONSchema.jl**](https://github.com/abap34/Struct2JSONSchema.jl) generates
  2020-12 schemas from existing structs without modifying them, with hooks to customize
  the schema of types and fields (formats, descriptions from docstrings, defaults,
  optional fields), and never fails: what it cannot represent becomes `{}`.

### From JSON to Julia types

* [**JSON3.jl**](https://github.com/quinnj/JSON3.jl) generates types from *sample* JSON
  documents (`JSON3.@generatetypes`, `JSON3.writetypes`), inferred from the data rather
  than from a schema, to read documents with StructTypes.jl.
* [**JSON.jl**](https://github.com/JuliaIO/JSON.jl) 1.x reads JSON directly into
  hand-written types (`JSON.parse(json, T)`), with the conventions of StructUtils.jl for
  names, defaults and unions.

### In other languages

The idea of generating types from a schema is common elsewhere: for instance
[quicktype](https://quicktype.io) (many languages),
[datamodel-code-generator](https://github.com/koxudaxi/datamodel-code-generator) (Python,
Pydantic models) and Corvus.JsonSchema itself (C#).

## Comparison

| | JSONSchema2Types.jl | JSONSchema.jl | CorvusJsonSchema.jl | JSONSchemaGenerator.jl, Struct2JSONSchema.jl | JSON3.jl types |
|---|---|---|---|---|---|
| Direction | schema → Julia types | schema → validation (and simple types → schema) | schema → validation | Julia types → schema | sample JSON → Julia types |
| Drafts | 2020-12 (and earlier) | 4, 6, 7 | 4 to 2020-12 | 2020-12 (Struct2JSONSchema) | — |
| Typed access to documents | yes | no | no | — | yes |
| Reading and writing documents | yes, lossless (unknown properties kept) | — | — | — | yes |
| Validation | in constructors and when reading; 95% of the test suite | drafts 4–7 | 100% of the test suite | — | no |
| Numeric types | chosen by the user (`Int64`/`Float64`, `BigInt`/`BigFloat`, ...) | — | — | — | inferred |
| Output | a self-contained Julia module (one file or one per schema file) | — | — | a schema | a Julia module |

These packages can be combined. A schema can be used with JSONSchema2Types.jl for typed
access to documents and with CorvusJsonSchema.jl for a complete validation, e.g. of
documents coming from untrusted sources before reading them. And a schema written for
Julia types with Struct2JSONSchema.jl can be turned back into a module with
JSONSchema2Types.jl, to share the types with other languages and tools through the schema.
