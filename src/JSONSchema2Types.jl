"""
    JSONSchema2Types

Generate Julia types from a JSON Schema, together with functions to read and write JSON
documents conforming to the schema. See [`generate_module`](@ref).
"""
module JSONSchema2Types

using JSON

export generate_module

include("generator.jl")

end # module
