# https://pretty-rfc.herokuapp.com/RFC3986#base-uri
# https://www.ietf.org/rfc/rfc3986.txt (official but not html, not friendly)
#
using HTTP

u = URI("http://a/b/c/d;p?q")
@show isvalid(u);

T = typeof(u)

for (name, typ) in zip(fieldnames(T), T.types)
    println("type of the fieldname $name is $typ")
end

for name in fieldnames(T)
    println("field $name: $(getfield(u, name))")
end

u = URI("https://raw.githubusercontent.com/beerjson/beerjson/master/json/beer.json")
for name in fieldnames(T)
    println("field $name: $(getfield(u, name))")
end

u = URI("https://raw.githubusercontent.com/beerjson/beerjson/master/json/measureable_units.json")
@show isvalid(u);
#r=URI("#/definitions/VolumeUnitType")
#@show isvalid(r);
s = "https://raw.githubusercontent.com/beerjson/beerjson/master/json/measureable_units.json" *
    "#/definitions/VolumeUnitType"
@show isvalid(s);

path = "https://raw.githubusercontent.com/beerjson/beerjson/master/json/misc.json"
rel = "measureable_units.json#/definitions/VolumeType"
resolved = joinpath(dirname(path), rel)
ur = URI(resolved)
@show isvalid(u);

for name in fieldnames(T)
    println("field $name: $(getfield(ur, name))")
end

# Taken from JSONSchema.jl
# https://github.com/fredo-dedup/JSONSchema.jl/blob/master/src/schema.jl/#L13
function type_to_dict(x)
    return Dict(name => getfield(x, name) for name in fieldnames(typeof(x)))
end

# Taken from JSONSchema.jl
# https://github.com/fredo-dedup/JSONSchema.jl/blob/master/src/schema.jl#L17
function update_id(uri::HTTP.URI, s::String)
    id2 = HTTP.URI(s)
    if !isempty(id2.scheme)
        return id2
    end
    els = type_to_dict(uri)
    delete!(els, :uri)
    els[:fragment] = id2.fragment
    if !isempty(id2.path)
        oldpath = match(r"^(.*/).*$", uri.path)
        els[:path] = oldpath == nothing ? id2.path : oldpath.captures[1] * id2.path
    end
    return HTTP.URI(; els...)
end

u = URI("https://raw.githubusercontent.com/beerjson/beerjson/master/json/beer.json")
rel = "measureable_units.json#/definitions/VolumeType"
update_id(u, rel)
isvalid(update_id(u, rel))

u = URI("https://raw.githubusercontent.com/beerjson/beerjson/master/json/measureable_units.json")
rel = "#/definitions/VolumeUnitType"
update_id(u, rel)
isvalid(update_id(u, rel))