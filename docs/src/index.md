# JSONSchema2Types.jl

*Generate Julia types from a [JSON Schema](https://json-schema.org), together with
functions to read, validate and write JSON documents that conform to it.*

Given a JSON Schema, possibly spread over several files that reference each other with
`$ref`, [`generate_module`](@ref) writes a Julia module with:

* a `struct` for each object of the schema and a type for each `enum`, with keyword
  constructors that convert plain values and validate them against the schema;
* functions to read JSON documents into these types (`readjson`, `fromjson`) and to write
  them back (`writejson`, `tojson`), losslessly;
* nothing else to depend on but [JSON.jl](https://github.com/JuliaIO/JSON.jl): the
  generated module is self-contained, so it can be committed to, and used by, another
  project without depending on JSONSchema2Types.jl.

The main motivation is the [BeerJSON](https://github.com/beerjson/beerjson) schema, a
format for beer recipes and brewing ingredients spread over twenty schema files, whose
types would take a lot of work to write by hand. See the [BeerJSON](@ref beerjson) page
for the types generated from it, used to read and display real BeerJSON documents.

## Installation

The package is not registered yet. Install it from GitHub:

```julia
julia> using Pkg

julia> Pkg.add(url = "https://github.com/rmsrosa/JSONSchema2Types.jl")
```

## Quick start

```julia
julia> using JSONSchema2Types

julia> generate_module("product.schema.json", "ProductTypes.jl")
"ProductTypes.jl"

julia> include("ProductTypes.jl"); using .ProductTypes

julia> p = readjson(RootType, "product.json");      # read and validate a document

julia> p.price
12.5

julia> writejson("product-copy.json", p);            # and write it back
```

## Contents

* [Guide](@ref): how a schema is translated into Julia types, what is validated, how types
  are named, and the options of [`generate_module`](@ref).
* [Examples](@ref): small schemas from the JSON Schema documentation, step by step.
* [BeerJSON](@ref beerjson): the types generated from the BeerJSON schema, reading and
  displaying recipes, styles, water profiles and hop varieties.
* [API](@ref): the reference of the package and of the generated modules.
