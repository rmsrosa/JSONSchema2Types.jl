using JSONSchema2Types
using JSON
using Test

const EXAMPLES = joinpath(@__DIR__, "..", "examples")
const SAMPLES = joinpath(@__DIR__, "beerjson-1.0.1-samples")

"""
Generate a module from `schema` into a temporary file and load it into a fresh anonymous
module. Returns the generated module.
"""
function load_generated(schema; kwargs...)
    file = generate_module(schema, joinpath(mktempdir(), "generated.jl"); kwargs...)
    # the file contains a single `module ... end`, which evaluates to the module itself
    return Base.include(Module(), file)
end

# Compare JSON values regardless of the order of keys and of `1` vs `1.0`.
canon(x::AbstractDict) = Dict(String(k) => canon(v) for (k, v) in x)
canon(x::AbstractVector) = Any[canon(v) for v in x]
canon(x::Real) = x isa Bool ? x : Float64(x)
canon(x) = x

@testset "JSONSchema2Types.jl" begin

@testset "Identifiers" begin
    @test JSONSchema2Types.pascal_case("foo_bar.baz") == "FooBarBaz"
    @test JSONSchema2Types.pascal_case("fOO Bar-bAz") == "FOOBarBAz"
    @test JSONSchema2Types.type_identifier("2nd thing!") == "T2NdThing"
    @test JSONSchema2Types.field_identifier("first-name") == "first_name"
    @test JSONSchema2Types.field_identifier("end") == "end_"
    @test JSONSchema2Types.field_identifier("type") == "type"
    @test JSONSchema2Types.field_identifier("\$id") == "_id"
end

@testset "Features" begin
    M = load_generated(joinpath(@__DIR__, "schemas", "features.json"))
    T = M.Features

    # keyword-named and non-identifier properties
    @test fieldnames(T)[1:3] == (:id, :end_, :first_name)

    good = """
    {"id": "abc-1", "end": 3, "first-name": "Ann", "score": 9.5, "nickname": null,
     "color": "red", "mixed": 2.5, "tags": ["a-1", "b-2"],
     "tree": {"value": 1, "children": [{"value": 2, "parent": {"node": {"value": 3}}}]},
     "metadata": {"x": 1}, "shape": {"side": 2}, "labeled": {"radius": 1, "label": "c"},
     "counted": {"a": 1}}
    """
    x = M.fromjson(T, good)
    @test x.end_ == 3
    @test x.nickname === nothing
    @test x.color == M.Color("red")
    @test x.mixed.value == 2.5
    @test x.shape isa M.Square
    @test x.labeled.radius == 1.0 && x.labeled.label == "c"
    @test x.tree.children[1].parent.node.value == 3
    @test x.metadata == Dict("x" => 1)
    @test canon(JSON.parse(M.tojson(x))) == canon(JSON.parse(good))
    @test M.fromjson(T, M.tojson(x)) == x
    # `nothing` in a required nullable field is written as `null`; optional ones are omitted
    y = T(id = "a-1", end_ = 1, nickname = nothing)
    @test M.tojson(y) == """{"id":"a-1","end":1,"nickname":null}"""

    # keyword constructor converts plain values
    @test T(id = "a-1", end_ = 1, nickname = "N", color = "blue").color isa M.Color

    E = M.SchemaValidationError
    base = Dict{String, Any}("id" => "abc-1", "end" => 3, "nickname" => nothing)
    bad(k, v) = M.fromdict(T, merge(base, Dict{String, Any}(k => v)))
    @test_throws E bad("id", "ABC")                       # pattern through $ref
    @test_throws E bad("end", 1.5)                        # not an integer
    @test_throws E bad("first-name", "")                  # minLength
    @test_throws E bad("first-name", "abcdefghijk")       # maxLength
    @test_throws E bad("score", -1)                       # minimum
    @test_throws E bad("score", 10)                       # exclusiveMaximum
    @test_throws E bad("score", 0.3)                      # multipleOf
    @test_throws E bad("color", "pink")                   # enum
    @test_throws E bad("mixed", "b")                      # enum with mixed types
    @test_throws E bad("tags", String[])                  # minItems
    @test_throws E bad("tags", ["a-1", "a-1"])            # uniqueItems
    @test_throws E bad("tags", ["a-1", "B"])              # pattern of items through $ref
    @test_throws E bad("tree", Dict("children" => []))    # missing required property
    @test_throws E bad("metadata", Dict("x" => "y"))      # additionalProperties schema
    @test_throws E bad("shape", Dict("radius" => 0))      # exclusiveMinimum in oneOf option
    @test_throws E bad("shape", Dict("edge" => 1))        # no matching oneOf option
    @test_throws E bad("counted", Dict())                 # minProperties
    @test_throws E bad("unknown", 1)                      # additionalProperties: false
    @test_throws E M.fromdict(T, Dict("id" => "abc-1", "end" => 3))  # missing required
end

@testset "Additional properties are preserved" begin
    M = load_generated(joinpath(EXAMPLES, "acme_schemas", "acme_nestedschema.json"))
    json = """{"productId": 1, "productName": "x", "price": 1.5, "extra": {"a": [1, 2]}}"""
    p = M.fromjson(M.RootType, json)
    @test p._extra["extra"]["a"] == [1, 2]
    @test canon(JSON.parse(M.tojson(p))) == canon(JSON.parse(json))
    @test_throws M.SchemaValidationError M.fromjson(M.RootType, """{"productId": 1, "productName": "x", "price": 0}""")
end

@testset "References by \$id" begin
    acme = joinpath(EXAMPLES, "acme_schemas")
    @test_throws ErrorException generate_module(joinpath(acme, "acme_withreferenceschema.json"),
                                                joinpath(mktempdir(), "x.jl"))
    M = load_generated(joinpath(acme, "acme_withreferenceschema.json");
                       schemas = [joinpath(acme, "acme_tobereferredschema.json")])
    data = joinpath(acme, "acme_data.json")
    p = M.readjson(M.RootType, data)
    @test p.warehouseLocation.latitude == -78.75
    @test canon(JSON.parse(M.tojson(p))) == canon(JSON.parse(read(data, String)))
end

@testset "Other examples" begin
    for (file, kwargs) in [
        ("acme_schemas/acme_flatschema.json", ()),
        ("acme_schemas/acme_nestedschema_mod.json", ()),
        ("more_schemas/order_schema.json", ()),
        ("more_schemas/combined_schema.json", ()),
        ("more_schemas/enum_schema.json", ()),
    ]
        @test load_generated(joinpath(EXAMPLES, file); kwargs...) isa Module
    end
end

@testset "BeerJSON 1.0.1" begin
    M = load_generated(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json");
                       root_name = "BeerJSON", module_name = "BeerJSONTypes")
    @test M.RootType === M.BeerJSON
    # `allOf` with `$ref`s merges the properties of the referenced schemas
    @test (:name, :alpha_acid, :timing, :amount) ⊆ fieldnames(M.HopAdditionType)
    @test M.VolumeUnitType("l").value == "l"
    @test_throws M.SchemaValidationError M.VolumeUnitType("litre")

    files = [joinpath(dir, f) for dir in readdir(SAMPLES; join = true) if isdir(dir)
             for f in readdir(dir) if endswith(f, ".json")]
    @test length(files) == 43
    for file in files
        x = M.readjson(M.RootType, file)
        @test canon(JSON.parse(M.tojson(x))) == canon(JSON.parse(read(file, String)))
        @test M.fromjson(M.RootType, M.tojson(x)) == x
    end

    # writing to a file
    x = M.readjson(M.RootType, joinpath(SAMPLES, "real", "SourMash.json"))
    out = M.writejson(joinpath(mktempdir(), "out.json"), x)
    @test M.readjson(M.RootType, out) == x
end

@testset "Module name clashing with a type name" begin
    @test_throws ArgumentError generate_module(joinpath(EXAMPLES, "more_schemas", "order_schema.json"),
                                               joinpath(mktempdir(), "x.jl"); module_name = "Order")
end

@testset "Committed examples load" begin
    for file in readdir(joinpath(EXAMPLES, "generated"); join = true)
        @test Base.include(Module(), file) isa Module
    end
end

@testset "Committed examples are up to date" begin
    dir = mktempdir()
    gen = joinpath(EXAMPLES, "generated")
    generate_module(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json"), joinpath(dir, "BeerJSON.jl");
                    root_name = "BeerJSON", module_name = "BeerJSONTypes")
    @test read(joinpath(dir, "BeerJSON.jl"), String) == read(joinpath(gen, "BeerJSON.jl"), String)
end

end
