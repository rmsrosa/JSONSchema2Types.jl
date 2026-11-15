using JSONSchema2Types
using JSON
using Dates
using Test

const EXAMPLES = joinpath(@__DIR__, "..", "examples")
const SAMPLES = joinpath(@__DIR__, "beerjson-1.0.1-samples")

"""
Generate a module from `schema` into a temporary file and load it into a fresh anonymous
module. Returns the generated module.
"""
function load_generated(schema; split = false, kwargs...)
    output = joinpath(mktempdir(), split ? "generated" : "generated.jl")
    file = generate_module(schema, output; split, kwargs...)
    # the file contains a single `module ... end`, which evaluates to the module itself
    return Base.include(Module(), file)
end

# Compare JSON values regardless of the order of keys and of `1` vs `1.0`.
canon(x::AbstractDict) = Dict(String(k) => canon(v) for (k, v) in x)
canon(x::AbstractVector) = Any[canon(v) for v in x]
canon(x::Real) = x isa Bool ? x : Float64(x)
canon(x) = x

approx(a, b) = a == b
approx(a::Real, b::Real) = isapprox(a, b; rtol = 1e-12)
approx(a::AbstractDict, b::AbstractDict) = keys(a) == keys(b) && all(approx(a[k], b[k]) for k in keys(a))
approx(a::AbstractVector, b::AbstractVector) = length(a) == length(b) && all(approx(x, y) for (x, y) in zip(a, b))

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
    @test string(x.color) == "red" && "$(x.color)" == "red" && repr(x.color) == "Color(\"red\")"
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
    # named tuples are accepted as objects
    @test T(id = "a-1", end_ = 1, nickname = nothing, labeled = (radius = 2, label = "c")).labeled.radius == 2.0
    @test T(id = "a-1", end_ = 1, nickname = nothing, metadata = (x = 1,)).metadata == Dict("x" => 1)

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

    # `unevaluatedProperties: false` closes an `allOf`-composed type, including the keys
    # merged from the referenced schemas
    @test M.fromdict(M.StrictLabeledCircle, Dict("radius" => 1, "label" => "c")).label == "c"
    @test !hasfield(M.StrictLabeledCircle, :_extra)
    @test_throws E M.fromdict(M.StrictLabeledCircle, Dict("radius" => 1, "lable" => "c"))
    # `unevaluatedProperties` with a schema types the additional properties
    t = M.fromdict(M.TypedExtra, Dict("name" => "n", "weight" => 2))
    @test t._extra == Dict("weight" => 2.0) && fieldtype(M.TypedExtra{Int64, Float64}, :_extra) == Dict{String, Float64}
    @test_throws E M.fromdict(M.TypedExtra, Dict("name" => "n", "weight" => "heavy"))
    @test bad("strict", Dict("radius" => 1)).strict isa M.StrictLabeledCircle
    # `additionalProperties: false` in a subschema of `allOf` applies to the instance as a
    # whole, as JSON Schema specifies: it rejects the `label` of the other subschema
    @test M.fromdict(M.ClosedLabeledCircle, Dict("radius" => 1)).radius == 1.0
    @test_throws E M.fromdict(M.ClosedLabeledCircle, Dict("radius" => 1, "label" => "c"))

    # `deprecated` is flagged in the docstrings
    code = read(generate_module(joinpath(@__DIR__, "schemas", "features.json"),
                                joinpath(mktempdir(), "features.jl")), String)
    @test occursin("- `old_name::Union{Nothing, String}` (deprecated): Use `first-name` instead.", code)
    @test occursin("**Deprecated.** Additional values must be numbers.", code)
end

@testset "Keywords checked at runtime" begin
    M = load_generated(joinpath(@__DIR__, "schemas", "validation.json"))
    T = M.Validation
    E = M.SchemaValidationError
    ok(d) = M.fromdict(T, d)
    bad(d) = @test_throws E M.fromdict(T, d)

    # not
    @test ok(Dict("password" => "s3cret")).password == "s3cret"
    bad(Dict("password" => "123456"))
    # oneOf: exactly one option must match
    @test ok(Dict("number" => 1.5)).number == 1.5
    @test ok(Dict("number" => -2)).number == -2
    bad(Dict("number" => 5))
    @test ok(Dict("shape" => Dict("radius" => 1, "ratio" => 2))).shape isa M.Ellipse
    bad(Dict("shape" => Dict("radius" => 1)))                  # both Circle and Ellipse
    bad(Dict("shape" => Dict("ratio" => 1)))                   # neither
    # anyOf: the constraints of the options are checked, not only their types
    @test ok(Dict("code" => "abc")).code == "abc"
    @test ok(Dict("code" => 100)).code == 100
    bad(Dict("code" => "abcd"))
    bad(Dict("code" => 99))
    # format
    @test ok(Dict("date" => "2026-11-13", "email" => "a@b.org", "homepage" => "https://x.org/a",
                  "id" => "123e4567-e89b-12d3-a456-426614174000", "secret_format" => "anything")) isa T
    bad(Dict("date" => "13/11/2026"))
    bad(Dict("email" => "not an email"))
    bad(Dict("homepage" => "no scheme"))
    bad(Dict("id" => "123"))
    M.check_formats!(false)
    @test ok(Dict("date" => "13/11/2026")).date == "13/11/2026"
    M.check_formats!(true)
    # items and contains
    @test ok(Dict("tags" => ["a", "important"])).tags == ["a", "important"]
    bad(Dict("tags" => ["a", ""]))
    bad(Dict("tags" => ["a", "b"]))
    # patternProperties with additionalProperties: false, in a dict
    @test ok(Dict("labels" => Dict("x-a" => "1"))).labels == Dict("x-a" => "1")
    bad(Dict("labels" => Dict("x-a" => 1)))
    bad(Dict("labels" => Dict("y" => "1")))
    # if/then/else and dependentRequired on an object
    @test M.fromdict(M.Payment, Dict("method" => "card", "card_number" => "1", "billing_address" => "x")) isa M.Payment
    @test M.fromdict(M.Payment, Dict("method" => "cash")) isa M.Payment
    @test_throws E M.fromdict(M.Payment, Dict("method" => "card"))                   # then
    @test_throws E M.fromdict(M.Payment, Dict("method" => "cash", "card_number" => "1",
                                              "billing_address" => "x"))             # else
    @test_throws E M.fromdict(M.Payment, Dict("method" => "card", "card_number" => "1"))  # dependentRequired
    @test_throws E M.Payment(method = "card")                                        # also in constructors
    # patternProperties in a struct: matching properties are kept in `_extra`
    s = M.fromdict(M.Settings, Dict("name" => "n", "opt_a" => true))
    @test s._extra == Dict("opt_a" => true)
    @test M.tojson(s) == """{"name":"n","opt_a":true}"""
    @test_throws E M.fromdict(M.Settings, Dict("name" => "n", "opt_a" => 1))
    @test_throws E M.fromdict(M.Settings, Dict("name" => "n", "other" => true))
end

@testset "unevaluatedProperties and unevaluatedItems at runtime" begin
    M = load_generated(joinpath(@__DIR__, "schemas", "validation.json"))
    v(schema, x) = M._jsvalid(JSON.parse(schema), JSON.parse(x)) === nothing
    # properties evaluated by `allOf`, `anyOf`, `oneOf`, `if`/`then` and `dependentSchemas`
    s = """{"allOf": [{"properties": {"a": {}}}], "properties": {"b": {}}, "unevaluatedProperties": false}"""
    @test v(s, """{"a": 1, "b": 2}""") && !v(s, """{"a": 1, "c": 3}""")
    s = """{"anyOf": [{"properties": {"a": {"type": "integer"}}}, {"properties": {"b": {}}, "required": ["b"]}],
            "unevaluatedProperties": false}"""
    @test v(s, """{"a": 1, "b": 2}""")                     # both options valid: both evaluated
    @test !v(s, """{"a": "x", "c": 3}""")
    s = """{"if": {"properties": {"kind": {"const": "card"}}}, "then": {"properties": {"number": {}}},
            "else": {"properties": {"cash": {}}}, "properties": {"kind": {}}, "unevaluatedProperties": false}"""
    @test v(s, """{"kind": "card", "number": 1}""") && !v(s, """{"kind": "card", "cash": 1}""")
    @test v(s, """{"kind": "x", "cash": 1}""") && !v(s, """{"kind": "x", "number": 1}""")
    s = """{"dependentSchemas": {"a": {"properties": {"b": {}}}}, "properties": {"a": {}}, "unevaluatedProperties": false}"""
    @test v(s, """{"a": 1, "b": 2}""") && !v(s, """{"b": 2}""")
    # `not` does not evaluate anything; a typed `unevaluatedProperties`
    s = """{"not": {"properties": {"a": {"type": "string"}}, "required": ["a"]}, "unevaluatedProperties": {"type": "integer"}}"""
    @test v(s, """{"a": 1}""") && !v(s, """{"a": 1.5}""")
    # items evaluated by `prefixItems`, `contains` and `allOf`
    s = """{"prefixItems": [{"type": "string"}], "contains": {"type": "integer"}, "unevaluatedItems": false}"""
    @test v(s, """["s", 1, 2]""") && !v(s, """["s", 1, true]""")
    s = """{"allOf": [{"prefixItems": [{}, {}]}], "unevaluatedItems": {"type": "boolean"}}"""
    @test v(s, """[1, "x", true]""") && !v(s, """[1, "x", 3]""")
    # nested: annotations of a valid `$ref`-inlined subschema (an `allOf` here) count
    s = """{"allOf": [{"allOf": [{"properties": {"a": {}}}]}], "unevaluatedProperties": false}"""
    @test v(s, """{"a": 1}""") && !v(s, """{"z": 1}""")
end

@testset "Type names" begin
    # inline enums get an `Enum` suffix, after the name of the parent without `Type`/`Base`
    M = load_generated(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json"); root_name = "BeerJSON")
    @test isdefined(M, :RecipeTypeEnum) && isdefined(M, :FermentableTypeEnum) &&
          isdefined(M, :BoilStepChillingTypeEnum) && isdefined(M, :HopVarietyFormEnum)
    @test fieldtype(M.RecipeType, :type) == M.RecipeTypeEnum
    # a property named like its parent: `beerjson` in `BeerJSON`
    @test fieldtype(M.BeerJSON, :beerjson) == M.BeerJSONContent
    # chosen names
    names = Dict("recipe.json#/definitions/RecipeType/properties/type" => "RecipeKind",
                 "#/properties/beerjson" => "BeerJSONDocument",
                 "measureable_units.json#/definitions/VolumeType" => "Volume")
    N = load_generated(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json");
                       root_name = "BeerJSON", type_names = names)
    @test fieldtype(N.RecipeType, :type) == N.RecipeKind
    @test fieldtype(N.BeerJSON, :beerjson) == N.BeerJSONDocument
    @test N.Volume(unit = "l", value = 1).value == 1.0 && !isdefined(N, :VolumeType)
    file = joinpath(mktempdir(), "x.jl")
    @test_logs (:warn, r"does not name a generated type") generate_module(
        joinpath(EXAMPLES, "acme_schemas", "acme_flatschema.json"), file; type_names = Dict("#/nowhere" => "X"))
    @test_throws ArgumentError generate_module(joinpath(EXAMPLES, "acme_schemas", "acme_flatschema.json"), file;
                                               type_names = Dict("#" => "not valid"))
end

@testset "References: \$id, \$anchor and downloads" begin
    remote = Dict("https://example.org/remote/color.json" =>
                  """{"\$id": "https://example.org/remote/color.json", "enum": ["red", "blue"]}""")
    fetched = String[]
    fetch(url) = (push!(fetched, url); remote[url])
    schema = joinpath(@__DIR__, "schemas", "ids", "root.json")
    @test_throws ErrorException generate_module(schema, joinpath(mktempdir(), "x.jl"))  # remote, no downloads
    M = load_generated(schema; download = fetch)
    @test fetched == ["https://example.org/remote/color.json"]
    T = M.Customer
    # `#name` is an `$anchor`; `address.json` is a nested `$id`, resolved against the
    # `$id` of the root, and `#/$defs/Street` inside it is relative to that nested resource
    @test fieldtype(T, :address) == Union{Nothing, M.Address}
    x = M.fromdict(T, Dict("name" => "Ann", "address" => Dict("street" => "1 Main St"),
                           "street" => "2 Side St", "favorite" => "red", "legacy" => 3))
    @test x.address.street == "1 Main St" && x.favorite.value == "red"
    E = M.SchemaValidationError
    @test_throws E M.fromdict(T, Dict("name" => ""))                                   # anchor's minLength
    @test_throws E M.fromdict(T, Dict("name" => "A", "address" => Dict("street" => "Main")))  # nested pattern
    @test_throws E M.fromdict(T, Dict("name" => "A", "street" => "Main"))              # absolute URI + pointer
    @test_throws E M.fromdict(T, Dict("name" => "A", "favorite" => "green"))           # downloaded enum
    @test_throws E M.fromdict(T, Dict("name" => "A", "legacy" => -1))                  # `"$id": "#legacy"`
    # URI resolution
    R = JSONSchema2Types.resolve_uri
    @test R("https://a.org/x/y.json", "z.json") == "https://a.org/x/z.json"
    @test R("https://a.org/x/y.json", "../z.json#/a") == "https://a.org/z.json#/a"
    @test R("https://a.org/x/y.json", "/z.json") == "https://a.org/z.json"
    @test R("https://a.org/x/y.json", "#foo") == "https://a.org/x/y.json#foo"
    @test R("https://a.org/x/y.json", "urn:example:z") == "urn:example:z"
end

@testset "Tuples" begin
    M = load_generated(joinpath(@__DIR__, "schemas", "tuples.json"))
    T = M.Tuples{Int64, Float64}
    @test fieldtype(T, :point) == Union{Nothing, Tuple{Float64, Float64}}
    @test fieldtype(T, :row) == Union{Nothing, Tuple{String, Vararg{Int64}}}
    @test fieldtype(T, :tagged) == Union{Nothing, Tuple{M.TuplesTaggedItem1Enum, M.TuplesTaggedItem2{Int64, Float64}, Vararg{Any}}}
    @test fieldtype(T, :optional) == Union{Nothing, Vector{Any}}
    @test fieldtype(T, :draft7) == Union{Nothing, Tuple{String, Bool}}
    json = """{"point": [1, 2.5], "row": ["r", 1, 2, 3], "tagged": ["a", {"x": 1}, null, 7],
               "optional": ["s"], "draft7": ["s", true]}"""
    x = M.fromjson(T, json)
    @test x.point == (1.0, 2.5) && x.row == ("r", 1, 2, 3) && x.draft7 == ("s", true)
    @test x.tagged[2].x == 1 && x.tagged[3] === nothing
    @test canon(JSON.parse(M.tojson(x))) == canon(JSON.parse(json))
    @test T(point = (3, 4)).point == (3.0, 4.0)
    E = M.SchemaValidationError
    @test_throws E M.fromjson(T, """{"point": [1, 2, 3]}""")      # closed tuple
    @test_throws E M.fromjson(T, """{"point": [1]}""")
    @test_throws E M.fromjson(T, """{"row": ["r", -1]}""")         # rest items checked
    @test_throws E M.fromjson(T, """{"tagged": ["c", {"x": 1}]}""")
    @test_throws E M.fromjson(T, """{"optional": ["s", "t"]}""")   # prefixItems checked at runtime
    @test_throws E M.fromjson(T, """{"draft7": ["s", true, 1]}""")
end

@testset "Typed formats" begin
    schema = joinpath(@__DIR__, "schemas", "formats.json")
    # by default, formatted strings stay strings
    S = load_generated(schema)
    @test fieldtype(S.Event, :day) == String
    M = load_generated(schema; typed_formats = true)
    T = M.Event
    @test fieldtype(T, :id) == Union{Nothing, M.UUIDs.UUID}
    @test fieldtype(T, :day) == M.Dates.Date
    @test fieldtype(T, :starts) == Union{Nothing, M.Dates.DateTime}
    @test fieldtype(T, :at) == Union{Nothing, String}                  # time stays a string
    @test fieldtype(T, :days) == Union{Nothing, Vector{M.Dates.Date}}
    x = M.fromjson(T, """{"id": "123E4567-E89B-12D3-A456-426614174000", "day": "2026-11-15",
                          "starts": "2026-11-15T10:30:00.250+02:00", "days": ["2026-01-01"], "in2026": "2026-02-03"}""")
    @test x.day == M.Dates.Date(2026, 11, 15)
    @test x.starts == M.Dates.DateTime(2026, 11, 15, 8, 30, 0, 250)    # converted to UTC
    @test x.days == [M.Dates.Date(2026, 1, 1)]
    # written back in normalized form: UTC date-times, lowercase UUIDs
    back = JSON.parse(M.tojson(x))
    @test back["starts"] == "2026-11-15T08:30:00.250Z" && back["day"] == "2026-11-15"
    @test back["id"] == "123e4567-e89b-12d3-a456-426614174000"
    @test M.fromjson(T, M.tojson(x)) == x
    @test T(day = M.Dates.Date(2026, 1, 2)).day == M.Dates.Date(2026, 1, 2)
    @test JSON.parse(M.tojson(T(day = "2026-01-02", starts = "2026-01-02T03:04:05Z")))["starts"] == "2026-01-02T03:04:05Z"
    E = M.SchemaValidationError
    @test_throws E M.fromjson(T, """{"day": "2026-13-01"}""")
    @test_throws E M.fromjson(T, """{"day": "2026-11-15", "starts": "2026-11-15 10:30"}""")
    @test_throws E M.fromjson(T, """{"day": "2026-11-15", "id": "123"}""")
    @test_throws E M.fromjson(T, """{"day": "2026-11-15", "in2026": "2025-02-03"}""")  # pattern on the string form
    # split output includes the formats runtime
    dir = joinpath(mktempdir(), "EventTypes")
    main = generate_module(schema, dir; typed_formats = true, split = true)
    @test "runtime_formats.jl" in readdir(dir)
    N = Base.include(Module(), main)
    @test Base.invokelatest(N.Event; day = "2026-01-01").day isa Dates.Date
end

@testset "Defaults" begin
    schema = joinpath(@__DIR__, "schemas", "defaults.json")
    # by default, optional fields are `nothing`
    S = load_generated(schema)
    @test S.Settings(name = "n").level === nothing
    M = load_generated(schema; use_defaults = true)
    x = M.Settings(name = "n")
    @test x.level == 3
    @test x.unit == M.Unit("l")                         # default of the referenced schema
    @test x.tags == ["a", "b"]
    @test x.size == M.Size(width = 1, height = 2)
    @test x.note === nothing && x.plain === nothing
    # missing properties get their defaults when reading, and are written out
    y = M.fromjson(M.Settings, """{"name": "n", "level": 5}""")
    @test y.level == 5 && y.unit == M.Unit("l")
    @test JSON.parse(M.tojson(y))["tags"] == ["a", "b"]
    # each value gets its own copy of a mutable default
    push!(x.tags, "c")
    @test M.Settings(name = "n").tags == ["a", "b"]
    code = read(generate_module(schema, joinpath(mktempdir(), "d.jl"); use_defaults = true), String)
    @test occursin("- `level::Union{Nothing, I}`: defaults to `3`.", code)
end

@testset "setfields and positional constructors" begin
    M = load_generated(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json"); root_name = "BeerJSON")
    v = M.VolumeType(unit = "l", value = 20)
    @test M.setfields(v; value = 40) == M.VolumeType(unit = "l", value = 40)
    @test M.setfields(v; unit = "gal").unit == M.VolumeUnitType("gal")
    @test v.value == 20.0                                   # unchanged
    @test_throws M.SchemaValidationError M.setfields(v; unit = "litre")
    @test_throws ArgumentError M.setfields(v; colour = "red")
    # positional constructors, as printed, and as used by ConstructionBase.jl/Accessors.jl
    @test M.VolumeType(M.VolumeUnitType("l"), 20.0) == v
    @test Core.eval(M, Meta.parse(sprint(show, v; context = :module => M))) == v
    @test M.VolumeType(getfield.(Ref(v), fieldnames(M.VolumeType))...) == v
    hop = M.fromjson(M.HopAdditionType, """{"name": "x", "alpha_acid": {"unit": "%", "value": 5},
                                            "timing": {}, "amount": {"unit": "g", "value": 2}}""")
    @test M.HopAdditionType(getfield.(Ref(hop), fieldnames(M.HopAdditionType))...) == hop
    @test M.setfields(hop; amount = (unit = "kg", value = 1)).amount isa M.MassType
end

@testset "Numeric types" begin
    M = load_generated(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json"); root_name = "BeerJSON")
    # by default, integers are `Int64` and other numbers `Float64`
    v = M.VolumeType(unit = "l", value = 20)
    @test v isa M.VolumeType{Int64, Float64} && v.value === 20.0
    @test repr(v) == "VolumeType(VolumeUnitType(\"l\"), 20.0)"
    # any `Integer` and `Real` types can be chosen
    w = M.VolumeType{Int, BigFloat}(unit = "l", value = 20)
    @test w.value isa BigFloat && repr(w) == "VolumeType{Int64, BigFloat}(VolumeUnitType(\"l\"), 20.0)"
    @test M.VolumeType{Int, Rational{Int}}(unit = "l", value = 0.5).value === 1 // 2
    @test M.VolumeType{Int32, Float32}(unit = "l", value = 2.5).value === 2.5f0
    # and they propagate to the nested structs
    file = joinpath(SAMPLES, "real", "SourMash.json")
    big = M.readjson(M.BeerJSON{BigInt, BigFloat}, file)
    recipe = only(big.beerjson.recipes)
    @test recipe isa M.RecipeType{BigInt, BigFloat}
    @test recipe.batch_size isa M.VolumeType{BigInt, BigFloat}
    @test recipe.ingredients.fermentable_additions[1].amount isa Union{M.MassType{BigInt, BigFloat}, M.VolumeType{BigInt, BigFloat}}
    # numbers are parsed with full precision for other floating-point types
    x = setprecision(BigFloat, 256) do
        M.fromjson(M.VolumeType{Int, BigFloat}, """{"unit": "l", "value": 1.000000000000000000001}""")
    end
    @test x.value > 1 && x.value - 1 < 1e-20
    @test M.fromjson(M.VolumeType, """{"unit": "l", "value": 1.000000000000000000001}""").value === 1.0
    # all the samples read with big numbers, with the same values
    for f in [joinpath(d, f) for d in readdir(SAMPLES; join = true) if isdir(d) for f in readdir(d) if endswith(f, ".json")]
        @test approx(canon(JSON.parse(M.tojson(M.readjson(M.BeerJSON{BigInt, BigFloat}, f)))), canon(JSON.parse(read(f, String))))
    end
    # integers out of range of the chosen type are rejected
    @test_throws M.SchemaValidationError M.fromjson(M.TimingType{Int8, Float64}, """{"step": 300}""")
    @test M.fromjson(M.TimingType{BigInt, Float64}, """{"step": 123456789012345678901234567890}""").step ==
          big"123456789012345678901234567890"
    # positional constructors infer the numeric types from their arguments
    @test M.VolumeType(M.VolumeUnitType("l"), big"2.5") isa M.VolumeType{Int64, BigFloat}
    @test M.setfields(w; value = 3).value isa BigFloat
    # the names of the type parameters are reserved
    dir = mktempdir()
    write(joinpath(dir, "s.json"), """{"title": "R", "type": "object",
        "properties": {"I": {"type": "integer"}, "T": {"\$ref": "#/\$defs/T"}},
        "\$defs": {"T": {"type": "object", "properties": {"x": {"type": "number"}}}}}""")
    N = load_generated(joinpath(dir, "s.json"))
    @test fieldnames(N.R) == (:I_, :T_, :_extra)
    r = N.fromjson(N.R{Int, BigFloat}, """{"I": 1, "T": {"x": 2.5}}""")
    @test r.I_ === 1 && r.T_.x isa BigFloat && N.tojson(r) == """{"I":1,"T":{"x":2.5}}"""
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

@testset "Split into several files" begin
    schema = joinpath(@__DIR__, "schemas", "split", "root.json")
    dir = joinpath(mktempdir(), "LibraryTypes")
    main = generate_module(schema, dir; split = true)
    @test main == joinpath(dir, "LibraryTypes.jl")
    # `author.json` and `book.json` use each other, so they share a file, after `common.json`
    @test sort(readdir(dir)) == ["LibraryTypes.jl", "author_and_book.jl", "common.jl", "root.jl", "runtime.jl"]
    code = read(main, String)
    @test findfirst("include(\"common.jl\")", code) < findfirst("include(\"author_and_book.jl\")", code) <
          findfirst("include(\"root.jl\")", code)
    @test !occursin("module", read(joinpath(dir, "author_and_book.jl"), String))
    M = Base.include(Module(), main)
    json = """{"authors": [{"name": "Machado", "country": "BR", "books": [{"title": "Dom Casmurro"}]}],
               "books": [{"title": "Dom Casmurro", "author": {"name": "Machado"}}]}"""
    x = M.fromjson(M.RootType, json)
    @test x.authors[1].books[1].title == "Dom Casmurro"
    @test canon(JSON.parse(M.tojson(x))) == canon(JSON.parse(json))
    # the single-file version has the same types
    S = load_generated(schema)
    @test S.fromjson(S.RootType, json) isa S.Library
end

@testset "BeerJSON 1.0.1" begin
    M = load_generated(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json");
                       root_name = "BeerJSON", module_name = "BeerJSONTypes", split = true)
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
        isdir(file) && (file = joinpath(file, basename(file) * ".jl"))
        @test Base.include(Module(), file) isa Module
    end
end

@testset "Committed examples are up to date" begin
    dir = joinpath(mktempdir(), "BeerJSONTypes")
    committed = joinpath(EXAMPLES, "generated", "BeerJSONTypes")
    generate_module(joinpath(EXAMPLES, "beerjson-1.0.1", "json", "beer.json"), dir;
                    root_name = "BeerJSON", module_name = "BeerJSONTypes", split = true)
    @test readdir(dir) == readdir(committed)
    for f in readdir(dir)
        @test read(joinpath(dir, f), String) == read(joinpath(committed, f), String)
    end
end

end
