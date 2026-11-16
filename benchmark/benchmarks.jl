# Benchmarks of reading, writing, constructing and modifying generated types.
#
# Usage, from the root of the repository:
#
#     julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'   # Julia ≥ 1.11
#     julia --project=benchmark benchmark/benchmarks.jl

using JSONSchema2Types, JSON, BenchmarkTools, Accessors, Printf
const REPO = dirname(@__DIR__)
const OUT = mktempdir()

include(generate_module(joinpath(REPO, "examples/acme_schemas/acme_nestedschema.json"), joinpath(OUT, "Acme.jl"); module_name = "AcmeTypes"))
include(generate_module(joinpath(REPO, "examples/beerjson-1.0.1/json/beer.json"), joinpath(OUT, "Beer"); root_name = "BeerJSON", split = true))
using .AcmeTypes: AcmeTypes
using .BeerJSONTypes: BeerJSONTypes
const A = AcmeTypes
const B = BeerJSONTypes

row(name, b) = @printf("%-62s %10s %8d allocs %10s\n", name, BenchmarkTools.prettytime(minimum(b).time),
                       minimum(b).allocs, BenchmarkTools.prettymemory(minimum(b).memory))

acme_json = """{"productId": 1, "productName": "An ice sculpture", "price": 12.5, "tags": ["cold", "ice"],
                "dimensions": {"length": 7.0, "width": 12.0, "height": 9.5}}"""
small = joinpath(REPO, "test/beerjson-1.0.1-samples/converted/RRSummerBitter.json")
big = joinpath(REPO, "test/beerjson-1.0.1-samples/converted/punk-ipa-2010-current.json")
small_json = read(small, String); big_json = read(big, String)
println("document sizes: Acme $(sizeof(acme_json)) B, RR Summer Bitter $(sizeof(small_json)) B, Punk IPA $(sizeof(big_json)) B\n")

println("== Reading and writing")
row("JSON.parse (Acme)", @benchmark JSON.parse($acme_json))
row("fromjson(Product, ...) (Acme)", @benchmark A.fromjson(A.Product, $acme_json))
row("JSON.parse (RR Summer Bitter)", @benchmark JSON.parse($small_json))
row("fromjson(RootType, ...) (RR Summer Bitter)", @benchmark B.fromjson(B.RootType, $small_json))
row("JSON.parse (Punk IPA)", @benchmark JSON.parse($big_json))
row("fromjson(RootType, ...) (Punk IPA)", @benchmark B.fromjson(B.RootType, $big_json))
row("fromjson(BeerJSON{BigInt, BigFloat}, ...) (Punk IPA)", @benchmark B.fromjson(B.BeerJSON{BigInt, BigFloat}, $big_json))
doc = B.fromjson(B.RootType, big_json)
row("tojson (Punk IPA)", @benchmark B.tojson($doc))
row("JSON.json of the parsed Dict (Punk IPA)", (d = JSON.parse(big_json); @benchmark JSON.json($d)))

println("\n== Constructing and modifying")
struct PlainVolume; unit::Symbol; value::Float64; end
row("plain struct PlainVolume(:l, 20.0) (baseline)", @benchmark PlainVolume(:l, 20.0))
row("VolumeType(unit = \"l\", value = 20)", @benchmark B.VolumeType(unit = "l", value = 20))
u = B.VolumeUnitType("l")
row("VolumeType(unit = VolumeUnitType(\"l\"), value = 20.0)", @benchmark B.VolumeType(unit = $u, value = 20.0))
row("VolumeType(VolumeUnitType(\"l\"), 20.0, ...) positional", @benchmark B.VolumeType{Int64, Float64}($u, 20.0))
row("VolumeUnitType(\"l\") (enum check)", @benchmark B.VolumeUnitType("l"))
v = B.VolumeType(unit = "l", value = 20)
row("setfields(volume; value = 40.0)", @benchmark B.setfields($v; value = 40.0))
row("@set volume.value = 40.0", @benchmark @set $v.value = 40.0)
recipe = only(doc.beerjson.recipes)
row("setfields(recipe; name = \"New\")  (recipe with $(length(fieldnames(typeof(recipe)))) fields)", @benchmark B.setfields($recipe; name = "New"))
row("@set recipe.name = \"New\"", @benchmark @set $recipe.name = "New")
row("@set recipe.batch_size.value = 40.0", @benchmark @set $recipe.batch_size.value = 40.0)
row("@set recipe.ingredients.hop_additions[1].amount.value = 0.05", @benchmark @set $recipe.ingredients.hop_additions[1].amount.value = 0.05)
p = A.fromjson(A.Product, acme_json)
row("setfields(product; price = 13.0)  (Acme, price > 0 checked)", @benchmark A.setfields($p; price = 13.0))
row("@set product.dimensions.width = 13.0  (Acme)", @benchmark @set $p.dimensions.width = 13.0)
dict = JSON.parse(big_json)
row("Dict baseline: dict[...][\"batch_size\"][\"value\"] = 40.0", @benchmark ($dict["beerjson"]["recipes"][1]["batch_size"]["value"] = 40.0))

println("\n== Reading fields")
row("recipe.batch_size.value", @benchmark $recipe.batch_size.value)
row("sum of the 14 hop amounts", @benchmark sum(h -> h.amount.value, $recipe.ingredients.hop_additions))
row("Dict baseline: sum of the 14 hop amounts", @benchmark sum(h -> h["amount"]["value"], $dict["beerjson"]["recipes"][1]["ingredients"]["hop_additions"]))

println("\n== With the checks off (`checks!(false)`), and validating later")
B.checks!(false)
row("fromjson(RootType, ...) (Punk IPA)", @benchmark B.fromjson(B.RootType, $big_json))
row("VolumeType(unit = \"l\", value = 20)", @benchmark B.VolumeType(unit = "l", value = 20))
hop = recipe.ingredients.hop_additions[1]
row("setfields(hop; name = \"y\")", @benchmark B.setfields($hop; name = "y"))
row("@set recipe.ingredients.hop_additions[1].amount.value = 0.05", @benchmark @set $recipe.ingredients.hop_additions[1].amount.value = 0.05)
B.checks!(true)
row("setfields(hop; name = \"y\") (checks on)", @benchmark B.setfields($hop; name = "y"))
row("violations(doc) (Punk IPA)", @benchmark B.violations($doc))
