# [BeerJSON](@id beerjson)

[BeerJSON](https://github.com/beerjson/beerjson) is an open format for beer recipes and
brewing data: fermentables, hops, cultures, water profiles, styles, equipment, and the
mash, boil, fermentation and packaging procedures. Its schema (version 1.0.1 here, in
`examples/beerjson-1.0.1/`) is spread over twenty files, with 92 types once translated.

The code on this page is run when the documentation is built, on sample documents from the
BeerJSON repository (in `test/beerjson-1.0.1-samples/`).

```@setup beer
using JSONSchema2Types, Markdown
const ROOT = pkgdir(JSONSchema2Types)
const SAMPLES = joinpath(ROOT, "test", "beerjson-1.0.1-samples")

# a number without a trailing `.0`, and a quantity, such as
# `VolumeType(unit = "l", value = 20)`, as "20 l"
num(v) = (v = round(v; sigdigits = 4); isinteger(v) ? string(Int(v)) : string(v))
q(::Nothing) = ""
q(x) = string(num(x.value), " ", x.unit)
q(x::Real) = num(x)
# minimum and maximum of a range
r(x) = x === nothing ? "" : string(q(x.minimum), " – ", q(x.maximum))
s(x) = x === nothing ? "" : string(x)

# a Markdown table, displayed as such in the documentation
function table(header, rows)
    cell(x) = replace(string(x), "|" => "\\|", "\n" => " ", "_" => "\\_", "*" => "\\*")
    io = IOBuffer()
    println(io, "| ", join(header, " | "), " |")
    println(io, "|", repeat(":---|", length(header)))
    for row in rows
        println(io, "| ", join(cell.(row), " | "), " |")
    end
    return Markdown.parse(String(take!(io)))
end
```

## Generating the types

The types are generated into a directory, with one file per schema file:

```@example beer
schema = joinpath(ROOT, "examples", "beerjson-1.0.1", "json", "beer.json")
main = generate_module(schema, joinpath(mktempdir(), "BeerJSONTypes");
                       root_name = "BeerJSON", split = true)
readdir(dirname(main))
```

```@example beer
include(main)
using .BeerJSONTypes
```

A BeerJSON document is an object with a single property, `beerjson`, which holds the
version of the format and lists of records: recipes, fermentables, hop varieties, styles,
water profiles...

```@example beer
fieldnames(BeerJSONContent)
```

The types follow the schema. For instance, a hop addition in a recipe:

```@example beer
@doc HopAdditionType
```

## A recipe

Let us read a recipe, converted from a BeerXML file of the
[Brewtarget](https://github.com/Brewtarget/brewtarget) examples:

```@example beer
doc = readjson(RootType, joinpath(SAMPLES, "converted", "RRSummerBitter.json"))
recipe = only(doc.beerjson.recipes)
table(["Recipe", ""], [
    ["Name", recipe.name],
    ["Type", recipe.type],
    ["Author", recipe.author],
    ["Style", "$(recipe.style.name) ($(recipe.style.category), $(recipe.style.style_guide))"],
    ["Batch size", q(recipe.batch_size)],
    ["Boil time", q(recipe.boil.boil_time)],
    ["Brewhouse efficiency", q(recipe.efficiency.brewhouse)],
])
```

Its ingredients:

```@example beer
ingredients = recipe.ingredients
table(["Fermentable", "Type", "Amount", "Color", "Origin"],
      [[f.name, f.type, q(f.amount), q(f.color), s(f.origin)]
       for f in ingredients.fermentable_additions])
```

```@example beer
table(["Hop", "Alpha acid", "Form", "Amount", "Added", "Time"],
      [[h.name, q(h.alpha_acid), s(h.form), q(h.amount), s(h.timing.use), q(h.timing.time)]
       for h in ingredients.hop_additions])
```

```@example beer
table(["Culture", "Type", "Form", "Producer", "Product"],
      [[c.name, c.type, c.form, s(c.producer), s(c.product_id)]
       for c in ingredients.culture_additions])
```

And its mash:

```@example beer
table(["Mash step", "Type", "Temperature", "Time"],
      [[m.name, m.type, q(m.step_temperature), q(m.step_time)] for m in recipe.mash.mash_steps])
```

Values are typed: the amount of a hop is a mass or a volume (a `oneOf` in the schema),
with units from an enumeration:

```@example beer
hop = first(ingredients.hop_additions)
hop.amount
```

## A hop schedule

The BrewDog Punk IPA recipe has fourteen hop additions:

```@example beer
punk = only(readjson(RootType, joinpath(SAMPLES, "converted", "punk-ipa-2010-current.json")).beerjson.recipes)
table(["Hop", "Alpha acid", "Amount", "Added", "Time"],
      [[h.name, q(h.alpha_acid), q(h.amount), s(h.timing.use), q(h.timing.time)]
       for h in punk.ingredients.hop_additions])
```

The total amount of hops, by addition:

```@example beer
total = Dict{String, Float64}()
for h in punk.ingredients.hop_additions
    total[string(h.timing.use)] = get(total, string(h.timing.use), 0.0) + h.amount.value
end
table(["Added", "Total (kg)"], [[k, round(v; digits = 3)] for (k, v) in sort(collect(total))])
```

## A style

Styles describe the ranges of the vital statistics of a beer:

```@example beer
style = only(readjson(RootType, joinpath(SAMPLES, "real", "StyleDryIrishStoutWithAllFields.json")).beerjson.styles)
table(["Style", ""], [
    ["Style", "$(style.category_number)$(style.style_letter) $(style.name) ($(style.style_guide))"],
    ["Original gravity", r(style.original_gravity)],
    ["Final gravity", r(style.final_gravity)],
    ["Bitterness", r(style.international_bitterness_units)],
    ["Color", r(style.color)],
    ["Alcohol by volume", r(style.alcohol_by_volume)],
    ["Carbonation", r(style.carbonation)],
])
```

```@example beer
print(style.overall_impression)
```

## A water profile

```@example beer
water = only(readjson(RootType, joinpath(SAMPLES, "real", "SampleWaterProfile.json")).beerjson.profiles)
ions = [:calcium, :magnesium, :sodium, :sulfate, :chloride, :bicarbonate]
table(["$(water.name)", ""], [[ion, q(getfield(water, ion))] for ion in ions])
```

This document also gives the pH of the water, which version 1.0.1 of the schema does not
describe for water profiles. It is allowed, since the schema does not forbid additional
properties there, so it is kept in the `_extra` field, and written back:

```@example beer
water._extra
```

## A hop variety

Records for ingredients have more information than their additions to a recipe:

```@example beer
variety = first(readjson(RootType, joinpath(SAMPLES, "real", "HopRecordWithAllFields.json")).beerjson.hop_varieties)
oil = variety.oil_content
table(["Hop variety", ""], [
    ["Name", variety.name],
    ["Origin", s(variety.origin)],
    ["Type", s(variety.type)],
    ["Alpha acid", q(variety.alpha_acid)],
    ["Beta acid", q(variety.beta_acid)],
    ["Substitutes", s(variety.substitutes)],
    ["Total oil", q(oil.total_oil_ml_per_100g)],
    ["Myrcene", q(oil.myrcene)],
    ["Humulene", q(oil.humulene)],
    ["Caryophyllene", q(oil.caryophyllene)],
    ["Farnesene", q(oil.farnesene)],
])
```

## Creating and writing a document

New records are created with keyword constructors, which accept plain values, and validate
them. A hop addition for a dry hop:

```@example beer
dry_hop = HopAdditionType(
    name = "Cascade",
    alpha_acid = (unit = "%", value = 5.5),
    form = "pellet",
    amount = Dict("unit" => "g", "value" => 50),
    timing = Dict("use" => "add_to_fermentation", "duration" => Dict("unit" => "day", "value" => 4)),
)
print(tojson(dry_hop; pretty = true))
```

Structs are immutable, so to change a record, build a new one. Here we add the dry hop to
the recipe and double the batch size, and then write the recipe to a new BeerJSON document:

```@example beer
fields(x) = Dict(n => getfield(x, n) for n in fieldnames(typeof(x)))
new_ingredients = IngredientsType(; fields(ingredients)...,
    hop_additions = [ingredients.hop_additions; dry_hop])
new_recipe = RecipeType(; fields(recipe)...,
    name = recipe.name * " (dry hopped)",
    batch_size = VolumeType(unit = recipe.batch_size.unit, value = 2 * recipe.batch_size.value),
    ingredients = new_ingredients)
new_doc = BeerJSON(beerjson = BeerJSONContent(version = 1.0, recipes = [new_recipe]))
file = writejson(joinpath(mktempdir(), "dry-hopped.json"), new_doc)
readjson(RootType, file) == new_doc
```

Invalid values are rejected, when constructing a value or reading a document:

```@example beer
try
    VolumeType(unit = "litre", value = 20)
catch err
    showerror(stdout, err)
end
```

```@example beer
try
    HopAdditionType(name = "Cascade", alpha_acid = Dict("unit" => "%", "value" => 5.5),
                    timing = Dict(), amount = Dict("unit" => "cm", "value" => 50))
catch err
    showerror(stdout, err)
end
```

## Reading every sample

Every sample document of BeerJSON 1.0.1 can be read, and written back unchanged:

```@example beer
using JSON
canon(x::AbstractDict) = Dict(String(k) => canon(v) for (k, v) in x)
canon(x::AbstractVector) = Any[canon(v) for v in x]
canon(x::Real) = x isa Bool ? x : Float64(x)
canon(x) = x
files = [joinpath(dir, f) for dir in readdir(SAMPLES; join = true) if isdir(dir)
         for f in readdir(dir) if endswith(f, ".json")]
unchanged = count(files) do f
    canon(JSON.parse(tojson(readjson(RootType, f)))) == canon(JSON.parse(read(f, String)))
end
"$unchanged of $(length(files)) documents read and written back unchanged"
```
