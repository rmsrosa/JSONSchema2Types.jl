# ---------------------------------------------------------------------------------------
# Generation of Julia types from JSON Schemas
# ---------------------------------------------------------------------------------------

const RUNTIME_FILE = joinpath(@__DIR__, "runtime.jl")
include_dependency(RUNTIME_FILE)
const RUNTIME_CODE = read(RUNTIME_FILE, String)
const FORMATS_FILE = joinpath(@__DIR__, "runtime_formats.jl")
include_dependency(FORMATS_FILE)
const FORMATS_CODE = read(FORMATS_FILE, String)

# Julia types for string formats, with `typed_formats = true`
const FORMAT_TYPES = Dict(
    "date" => "Dates.Date",
    "date-time" => "Dates.DateTime",
    "uuid" => "UUIDs.UUID",
)

const PRIMITIVE_TYPES = Dict(
    "string" => "String",
    "number" => "%T%",     # placeholders for the numeric type parameters of the structs,
    "integer" => "%I%",    # named when the code is written (see `emit_struct`)
    "boolean" => "Bool",
    "null" => "Nothing",
)

# Names that cannot be used as field names (keyword arguments) in the generated code.
const RESERVED_NAMES = Set([
    "abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do", "else",
    "elseif", "end", "export", "false", "finally", "for", "function", "global", "if",
    "import", "in", "isa", "let", "local", "macro", "module", "mutable", "new", "outer",
    "primitive", "public", "quote", "return", "struct", "true", "try", "type", "using",
    "where", "while", "nothing", "missing", "Any", "Nothing", "String", "Bool", "Int64",
    "Float64", "Vector", "Dict", "Union",
])
# `type` is not a reserved word in Julia, so we allow it as a field name.
delete!(RESERVED_NAMES, "type")

# Constraint keywords that are checked at construction time.
const VALUE_CONSTRAINTS = (
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    "minLength", "maxLength", "pattern", "minItems", "maxItems", "uniqueItems",
    "minProperties", "maxProperties",
)

# --- Data structures describing the generated code ---

"""
    TypeRef

Julia type expression, as a string, together with the names of the generated types it
depends on.
"""
struct TypeRef
    expr::String
    deps::Vector{String}
end
TypeRef(expr::String) = TypeRef(expr, String[])

struct FieldDef
    name::String          # Julia field name
    key::String           # JSON property name
    type::TypeRef         # type of the field, as specified by the schema
    required::Bool
    nullable::Bool
    constraints::Union{Nothing, Dict{String, Any}}
    description::String
    deprecated::Bool
    default::Union{Nothing, Some}   # default value of an optional field (with `use_defaults`)
end

mutable struct ObjectDef
    name::String
    location::String
    description::String
    fields::Vector{FieldDef}
    additional_properties::Bool
    extra_field::Union{Nothing, String}   # field holding additional properties
    extra_type::TypeRef                    # type of the values of additional properties
    min_properties::Union{Nothing, Int}
    max_properties::Union{Nothing, Int}
    schema::Union{Nothing, Dict{String, Any}}  # keywords checked on the whole object
end

struct EnumDef
    name::String
    location::String
    description::String
    values::Vector{Any}
    valuetype::String
end

"""
    Generator

State of the generation: loaded schema files, generated types and their names.
"""
mutable struct Generator
    root_file::String
    root_name::String
    files::Dict{String, Any}                       # absolute path => parsed schema
    uris::Dict{String, Tuple{String, String}}      # absolute URI (with `#anchor`) => (file, pointer)
    bases::Dict{String, Vector{Pair{String, String}}} # file => [pointer => base URI] where `$id`s are
    filebase::Dict{String, String}                 # file => URI it was loaded from
    fetch::Union{Nothing, Function}                # downloads remote schemas: url -> content
    typed_formats::Bool                            # translate some string formats into Julia types
    used_formats::Bool                             # whether any typed format was used
    use_defaults::Bool                             # optional fields default to the schema `default`
    types::Dict{String, Union{ObjectDef, EnumDef}} # location => definition
    names::Dict{String, String}                    # location => type name
    taken::Dict{String, String}                    # type name => location
    order::Vector{String}                          # locations in discovery order
    overrides::Dict{String, String}                # "file.json#pointer" => type name
    used_overrides::Set{String}
end

Generator(root_file::String, root_name::String) = Generator(
    root_file, root_name, Dict{String, Any}(), Dict{String, Tuple{String, String}}(),
    Dict{String, Vector{Pair{String, String}}}(), Dict{String, String}(), nothing, false, false, false,
    Dict{String, Union{ObjectDef, EnumDef}}(),
    Dict{String, String}(), Dict{String, String}(), String[], Dict{String, String}(),
    Set{String}(),
)

# --- Utilities ---

"""
    pascal_case(s::AbstractString)

Return a Pascal case version of the string `s`.

Pascal case changes, if necessary, every initial word character to uppercase, removes
every word separator ` `, `-`, `_`, and `.`, and does not change the case of the remaining
characters.

# Examples

```jldoctest
julia> JSONSchema2Types.pascal_case("foo_bar.baz")
"FooBarBaz"

julia> JSONSchema2Types.pascal_case("fOO Bar-bAz")
"FOOBarBAz"
```
"""
pascal_case(s::AbstractString) = replace(titlecase(s; strict = false), r"[ \-_.]" => "")

"""
    type_identifier(s)

Turn `s` into a valid name for a Julia type.
"""
function type_identifier(s::AbstractString)
    name = replace(pascal_case(s), r"[^A-Za-z0-9_]" => "")
    isempty(name) && (name = "Type")
    isdigit(first(name)) && (name = "T" * name)
    return name
end

"""
    field_identifier(s)

Turn the JSON property name `s` into a valid name for a Julia field.
"""
function field_identifier(s::AbstractString)
    name = replace(s, r"[^A-Za-z0-9_]" => "_")
    isempty(name) && (name = "_")
    isdigit(first(name)) && (name = "_" * name)
    name in RESERVED_NAMES && (name *= "_")
    return name
end

"""
    escape_docstring(s)

Escape `s` so that it can be put inside a triple-quoted docstring.
"""
escape_docstring(s::AbstractString) =
    replace(s, "\\" => "\\\\", "\$" => "\\\$", "\"\"\"" => "\\\"\\\"\\\"")

isobject(x) = x isa AbstractDict

"""
    load_schema!(gen, path; uri = nothing)

Load (and cache) the JSON schema in the file `path`, and index the URIs of its resources:
every `\$id` (resolved against the enclosing base URI), every `\$anchor`, and the file
itself. `uri` is the URI the file was obtained from (for downloaded schemas); it defaults to
the `file://` URI of `path`.
"""
function load_schema!(gen::Generator, path::AbstractString; uri = nothing)
    path = abspath(normpath(path))
    haskey(gen.files, path) && return gen.files[path]
    isfile(path) || error("Schema file not found: $path")
    schema = JSON.parse(read(path, String))
    gen.files[path] = schema
    base = uri === nothing ? file_uri(path) : String(uri)
    gen.filebase[path] = base
    gen.uris[base] = (path, "")
    gen.bases[path] = Pair{String, String}[]
    index_uris!(gen, path, schema, "", base)
    return schema
end

file_uri(path::AbstractString) = "file://" * replace(path, '\\' => '/')

function index_uris!(gen::Generator, path::String, node, pointer::String, base::String)
    if node isa AbstractVector
        for (i, sub) in enumerate(node)
            index_uris!(gen, path, sub, pointer * "/" * string(i - 1), base)
        end
        return
    end
    isobject(node) || return
    id = get(node, "\$id", nothing)
    # draft-04 used `id`; only consider it where it cannot be a property named `id`
    id === nothing && get(node, "id", nothing) isa AbstractString && haskey(node, "\$schema") && (id = node["id"])
    if id isa AbstractString
        if startswith(id, "#")
            # before 2019-09, `"$id": "#name"` defined a plain-name anchor
            gen.uris[base * id] = (path, pointer)
        else
            base = strip_fragment(resolve_uri(base, id))
            gen.uris[base] = (path, pointer)
            push!(gen.bases[path], pointer => base)
        end
    end
    anchor = get(node, "\$anchor", nothing)
    anchor isa AbstractString && (gen.uris[base * "#" * anchor] = (path, pointer))
    # `$dynamicAnchor`/`$dynamicRef` are resolved statically, as `$anchor`/`$ref`
    danchor = get(node, "\$dynamicAnchor", nothing)
    danchor isa AbstractString && !haskey(gen.uris, base * "#" * danchor) &&
        (gen.uris[base * "#" * danchor] = (path, pointer))
    if haskey(node, "\$dynamicRef") && !haskey(node, "\$ref")
        node["\$ref"] = node["\$dynamicRef"]
        delete!(node, "\$dynamicRef")
    end
    # only subschemas: an `$id` inside an unknown keyword is not an identifier
    for (k, v) in node
        if k in SCHEMA_KEYS || k in SCHEMA_LIST_KEYS
            index_uris!(gen, path, v, pointer * "/" * escape_pointer_segment(k), base)
        elseif (k in SCHEMA_MAP_KEYS || k in ("\$defs", "definitions", "dependencies")) && isobject(v)
            for (name, sub) in v
                index_uris!(gen, path, sub, pointer * "/" * escape_pointer_segment(k) * "/" *
                            escape_pointer_segment(name), base)
            end
        end
    end
end

"""
    resolve_uri(base, ref)

Resolve the URI reference `ref` against the absolute URI `base` (RFC 3986, section 5.2).
"""
function resolve_uri(base::AbstractString, ref::AbstractString)
    occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", ref) && return remove_dot_segments_uri(String(ref))
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*:(?://[^/?#]*)?)([^?#]*)", base)
    m === nothing && return String(ref)
    prefix, basepath = m.captures
    isempty(ref) && return String(base)
    startswith(ref, "#") && return strip_fragment(base) * ref
    startswith(ref, "//") && return first(split(prefix, ':')) * ":" * ref
    path = startswith(ref, "/") ? ref : (basepath[1:something(findlast('/', basepath), 0)] * ref)
    return remove_dot_segments_uri(prefix * path)
end

function remove_dot_segments_uri(uri::String)
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*:(?://[^/?#]*)?)([^?#]*)(.*)$", uri)
    m === nothing && return uri
    prefix, path, rest = m.captures
    out = String[]
    segs = split(path, '/')
    for (i, seg) in enumerate(segs)
        if seg == ".."
            length(out) > 1 && pop!(out)
            i == length(segs) && push!(out, "")
        elseif seg == "."
            i == length(segs) && push!(out, "")
        else
            push!(out, seg)
        end
    end
    return prefix * join(out, '/') * rest
end

# The base URI at a location: that of the innermost enclosing `$id`, or of the file.
function base_uri(gen::Generator, file::String, pointer::String)
    load_schema!(gen, file)
    base = gen.filebase[file]
    best = -1
    for (p, b) in gen.bases[file]
        if (p == "" || pointer == p || startswith(pointer, p * "/")) && length(p) > best
            base, best = b, length(p)
        end
    end
    return base
end

unescape_pointer_segment(s) = replace(percent_unescape(s), "~1" => "/", "~0" => "~")

function percent_unescape(s::AbstractString)
    occursin('%', s) || return String(s)
    out = IOBuffer()
    bytes = codeunits(s)
    n = length(bytes)
    j = 1
    while j <= n
        hex = j + 2 <= n ? tryparse(UInt8, String(bytes[j+1:j+2]); base = 16) : nothing
        if bytes[j] == UInt8('%') && hex !== nothing
            write(out, hex)
            j += 3
        else
            write(out, bytes[j])
            j += 1
        end
    end
    return String(take!(out))
end

"""
    get_node(gen, file, pointer)

Return the subschema of the schema in `file` at the JSON pointer `pointer`.
"""
function get_node(gen::Generator, file::String, pointer::String)
    node = load_schema!(gen, file)
    pointer == "" && return node
    startswith(pointer, "/") || error("Unsupported JSON pointer `$pointer` in $file")
    for raw in split(pointer[2:end], "/")
        seg = unescape_pointer_segment(raw)
        if node isa AbstractVector
            node = node[parse(Int, seg) + 1]
        elseif isobject(node) && haskey(node, seg)
            node = node[seg]
        else
            error("Cannot resolve JSON pointer `$pointer` in $file")
        end
    end
    return node
end

"""
    resolve_ref(gen, file, ref, pointer = "") -> (file, pointer)

Resolve the `\$ref` value `ref`, found in the schema file `file` at the JSON pointer
`pointer`. The reference is resolved against the base URI there (set by the enclosing
`\$id`s), and may point to a loaded schema by its `\$id`, to a subschema with a `\$id` or
`\$anchor`, to a file relative to `file`, or, when downloads are enabled, to a remote schema.
"""
function resolve_ref(gen::Generator, file::String, ref::AbstractString, pointer::AbstractString = "")
    base = base_uri(gen, file, String(pointer))
    path, fragment = occursin('#', ref) ? split(ref, '#'; limit = 2) : (ref, "")
    path, fragment = String(path), percent_unescape(String(fragment))
    uri = isempty(path) ? strip_fragment(base) : strip_fragment(resolve_uri(base, path))
    if !haskey(gen.uris, uri)
        local_file = isempty(path) || occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", path) ? nothing :
                     abspath(normpath(joinpath(dirname(file), path)))
        if startswith(uri, "file://") && isfile(uri[8:end])
            load_schema!(gen, uri[8:end])
        elseif local_file !== nothing && isfile(local_file)
            # relative references to local copies of schemas whose `$id`s are remote URLs
            load_schema!(gen, local_file)
            gen.uris[uri] = (abspath(normpath(local_file)), "")
        elseif gen.fetch !== nothing && occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", uri)
            fetch_schema!(gen, uri)
        else
            error("Cannot resolve `\$ref` to `$ref` (`$uri`) in $file. Give the schema as a local " *
                  "file (by a relative path, or with the `schemas` keyword argument, so that it is " *
                  "found by its `\$id`), or enable downloads with `download = true`.")
        end
    end
    target, root = gen.uris[uri]
    if isempty(fragment) || startswith(fragment, "/")
        return target, root * fragment
    end
    anchor = uri * "#" * fragment
    haskey(gen.uris, anchor) || error("Cannot resolve the anchor `#$fragment` of `\$ref` `$ref` in $file")
    return gen.uris[anchor]
end

# Download the schema at `uri`, save it under a temporary directory and load it.
function fetch_schema!(gen::Generator, uri::String)
    content = gen.fetch(uri)
    dir = mktempdir()
    name = something(match(r"([^/?#]+)$", uri), (; match = "schema.json")).match
    path = joinpath(dir, name)
    write(path, content)
    load_schema!(gen, path; uri)
    return path
end

download_schema(url::AbstractString) = String(take!(Downloads.download(url, IOBuffer())))

location(file, pointer) = string(file, "#", pointer)

strip_fragment(uri::AbstractString) = String(first(split(uri, '#'; limit = 2)))

"""
    name_hint(gen, file, pointer)

Suggest a type name for the subschema in `file` at the JSON pointer `pointer`, based on the
names of the definitions and properties along the pointer.
"""
function name_hint(gen::Generator, file::String, pointer::String)
    schema = load_schema!(gen, file)
    base = if file == gen.root_file
        gen.root_name
    else
        title = isobject(schema) ? get(schema, "title", nothing) : nothing
        type_identifier(title isa AbstractString ? title : splitext(basename(file))[1])
    end
    segs = pointer == "" ? String[] : unescape_pointer_segment.(split(pointer[2:end], "/"))
    node = schema
    i = 1
    while i <= length(segs)
        seg = segs[i]
        nxt = i < length(segs) ? segs[i+1] : nothing
        step = 1
        if seg in ("definitions", "\$defs") && nxt !== nothing
            base = type_identifier(nxt)
            step = 2
        elseif seg == "properties" && nxt !== nothing
            prop = type_identifier(nxt)
            stem = name_stem(base)
            # e.g. `beerjson` in `BeerJSON` gives `BeerJSONContent`, not `BeerJSONBeerjson`
            base = lowercase(prop) == lowercase(stem) ? stem * "Content" : stem * prop
            step = 2
        elseif seg == "allOf" && nxt !== nothing
            step = 2
        elseif seg in ("oneOf", "anyOf") && nxt !== nothing
            base *= "Option" * string(parse(Int, nxt) + 1)
            step = 2
        elseif seg in ("items", "prefixItems") && nxt !== nothing && occursin(r"^\d+$", nxt)
            base *= "Item" * string(parse(Int, nxt) + 1)
            step = 2
        elseif seg == "items"
            base *= "Item"
        elseif seg in ("additionalProperties", "unevaluatedProperties")
            base *= "Value"
        else
            base *= type_identifier(seg)
        end
        for s in segs[i:i+step-1]
            node = node isa AbstractVector ? node[parse(Int, s) + 1] :
                   isobject(node) ? get(node, s, nothing) : nothing
        end
        # inline subschemas with a `title` are named after it
        if !(seg in ("definitions", "\$defs")) && isobject(node) &&
                get(node, "title", nothing) isa AbstractString
            base = type_identifier(node["title"])
        end
        i += step
    end
    # inline enums are suffixed with `Enum`, e.g. `RecipeTypeEnum` for the `type` of `RecipeType`
    if !isempty(segs) && !occursin(r"^(definitions|\$defs)$", segs[end-1]) && isobject(node) &&
            (haskey(node, "enum") || haskey(node, "const")) && !haskey(node, "title") &&
            !endswith(base, "Enum")
        base *= "Enum"
    end
    return base
end

"""
    name_stem(name)

Name of a type without a trailing `Type` or `Base`, used as a prefix for the names of the
types of its properties (e.g. `Recipe` for `RecipeType`, `Fermentable` for
`FermentableBase`).
"""
function name_stem(name::AbstractString)
    m = match(r"^(.+?)(Type|Base)$", name)
    return m === nothing ? String(name) : String(m.captures[1])
end

"""
    register_name!(gen, file, pointer) -> String

Assign a unique type name to the subschema at the given location.
"""
function register_name!(gen::Generator, file::String, pointer::String)
    loc = location(file, pointer)
    haskey(gen.names, loc) && return gen.names[loc]
    key = basename(file) * "#" * pointer
    if haskey(gen.overrides, key)
        name = gen.overrides[key]
        haskey(gen.taken, name) &&
            throw(ArgumentError("the type name `$name` given in `type_names` for `$key` is already used"))
        push!(gen.used_overrides, key)
        gen.names[loc] = name
        gen.taken[name] = loc
        push!(gen.order, loc)
        return name
    end
    hint = name_hint(gen, file, pointer)
    isfree(n) = !haskey(gen.taken, n) && !(n in values(gen.overrides))
    name = hint
    if !isfree(name)
        name = type_identifier(splitext(basename(file))[1]) * hint
        k = 2
        while !isfree(name)
            name = hint * string(k)
            k += 1
        end
    end
    gen.names[loc] = name
    gen.taken[name] = loc
    push!(gen.order, loc)
    return name
end

# --- Analysis of the schemas ---

"""
    needs_named_type(gen, file, pointer, node)

Whether the subschema `node` is translated into a generated named type (struct or enum),
rather than into a builtin Julia type.
"""
function needs_named_type(gen::Generator, file::String, pointer::String, node)
    isobject(node) || return false
    (haskey(node, "enum") || haskey(node, "const")) && return true
    haskey(node, "properties") && return true
    if haskey(node, "allOf")
        props, _, merged = merge_allof(gen, file, pointer, node)
        return !isempty(props) || haskey(merged, "enum") || haskey(merged, "const")
    end
    return false
end

"""
    collect_constraints(node) -> Union{Nothing, Dict}

Collect the validation keywords of the subschema `node`.
"""
function collect_constraints(gen::Generator, file::String, node; pointer::String = "")
    isobject(node) || return nothing
    c = Dict{String, Any}()
    for k in VALUE_CONSTRAINTS
        haskey(node, k) || continue
        v = node[k]
        # draft-04 boolean form of exclusiveMinimum/exclusiveMaximum
        if k in ("exclusiveMinimum", "exclusiveMaximum") && v isa Bool
            if v
                base = k == "exclusiveMinimum" ? "minimum" : "maximum"
                haskey(node, base) && (c[k] = node[base]; delete!(c, base))
            end
            continue
        end
        if k in ("minimum", "maximum") && get(node, "exclusive" * uppercasefirst(k), false) === true
            continue
        end
        c[k] = v
    end
    # (with `prefixItems`, `items` only applies to the items after the prefix: checked at runtime)
    if get(node, "type", nothing) == "array" && isobject(get(node, "items", nothing)) && !haskey(node, "prefixItems")
        ic = item_constraints(gen, file, node["items"]; pointer = pointer * "/items")
        ic !== nothing && (c["items"] = ic)
    end
    return isempty(c) ? nothing : c
end

# Constraints of array items: follow `$ref`s to primitive schemas.
function item_constraints(gen::Generator, file::String, node, depth::Int = 0; pointer::String = "")
    isobject(node) || return nothing
    if haskey(node, "\$ref") && depth < 32
        f, p = resolve_ref(gen, file, node["\$ref"], pointer)
        target = get_node(gen, f, p)
        needs_named_type(gen, f, p, target) && return nothing
        return item_constraints(gen, f, target, depth + 1; pointer = p)
    end
    isobject(node) && (haskey(node, "enum") || haskey(node, "const") || haskey(node, "properties")) && return nothing
    return collect_constraints(gen, file, node; pointer)
end

"""
    merge_allof(gen, file, pointer, node) -> (properties, required, merged)

Merge the subschemas of an `allOf`, resolving the references. Returns the merged
properties as a vector of `(key, file, pointer, subschema)` (so that inline subschemas keep
their original locations), the set of required properties and the merged schema keywords.
"""
function merge_allof(gen::Generator, file::String, pointer::String, node, depth::Int = 0)
    depth > 32 && error("Too deeply nested `allOf`/`\$ref` at $(location(file, pointer))")
    props = Tuple{String, String, String, Any}[]
    required = String[]
    merged = Dict{String, Any}()
    function add!(f, p, n, d)
        isobject(n) || return
        if haskey(n, "\$ref")
            f2, p2 = resolve_ref(gen, f, n["\$ref"], p)
            add!(f2, p2, get_node(gen, f2, p2), d + 1)
        end
        if haskey(n, "allOf")
            for (i, sub) in enumerate(n["allOf"])
                add!(f, p * "/allOf/" * string(i - 1), sub, d + 1)
            end
        end
        if haskey(n, "properties")
            for (k, v) in n["properties"]
                idx = findfirst(x -> x[1] == k, props)
                entry = (String(k), f, p * "/properties/" * escape_pointer_segment(k), v)
                idx === nothing ? push!(props, entry) : (props[idx] = entry)
            end
        end
        append!(required, get(n, "required", String[]))
        for (k, v) in n
            k in ("\$ref", "allOf", "properties", "required", "additionalProperties",
                  "unevaluatedProperties", "description", "deprecated", "\$id", "\$schema",
                  "definitions", "\$defs") && continue
            merged[k] = v
        end
    end
    add!(file, pointer, node, depth)
    # these keywords are only taken from the outer schema
    for k in ("additionalProperties", "unevaluatedProperties", "description", "deprecated")
        haskey(node, k) && (merged[k] = node[k])
    end
    return props, unique(required), merged
end

escape_pointer_segment(s) = replace(String(s), "~" => "~0", "/" => "~1")

"""
    resolve_type(gen, file, pointer, node) -> (TypeRef, constraints)

Translate the subschema `node`, found in `file` at `pointer`, into a Julia type, generating
the named types it needs along the way. Also returns the validation constraints that apply
to values of this type and are not enforced by the type itself.
"""
function resolve_type(gen::Generator, file::String, pointer::String, node, depth::Int = 0)
    depth > 64 && error("Too deeply nested references at $(location(file, pointer))")
    node isa Bool && return TypeRef("Any"), nothing
    isobject(node) || return TypeRef("Any"), nothing

    # (with sibling `properties` or `allOf`, the `$ref` is merged into a struct for this node)
    if haskey(node, "\$ref") && !needs_named_type(gen, file, pointer, node)
        f, p = resolve_ref(gen, file, node["\$ref"], pointer)
        target = get_node(gen, f, p)
        if needs_named_type(gen, f, p, target)
            name = generate_named_type!(gen, f, p, target)
            return named_typeref(gen, name), nothing
        end
        t, c = resolve_type(gen, f, p, target, depth + 1)
        # constraints next to the `$ref` (ignored before draft 2019-09, but harmless)
        c2 = collect_constraints(gen, file, node; pointer)
        c2 !== nothing && (c = c === nothing ? c2 : merge(c, c2))
        return t, c
    end

    if needs_named_type(gen, file, pointer, node)
        name = generate_named_type!(gen, file, pointer, node)
        return named_typeref(gen, name), nothing
    end

    if haskey(node, "allOf")
        # `allOf` without properties: merge the keywords and translate the result
        _, required, merged = merge_allof(gen, file, pointer, node)
        return resolve_type(gen, file, pointer, merged, depth + 1)
    end

    for key in ("oneOf", "anyOf")
        haskey(node, key) || continue
        options = TypeRef[]
        for (i, sub) in enumerate(node[key])
            t, _ = resolve_type(gen, file, pointer * "/$key/" * string(i - 1), sub, depth + 1)
            push!(options, t)
        end
        return union_typeref(options), nothing
    end

    jtype = get(node, "type", nothing)
    if jtype isa AbstractVector
        options = TypeRef[]
        for t in jtype
            sub = Dict{String, Any}(node)
            sub["type"] = t
            tr, _ = resolve_type(gen, file, pointer, sub, depth + 1)
            push!(options, tr)
        end
        return union_typeref(options), collect_constraints(gen, file, node; pointer)
    end

    constraints = collect_constraints(gen, file, node; pointer)
    if jtype == "array"
        items = get(node, "items", nothing)
        # tuples: `prefixItems` (2020-12), or `items` as a list (earlier drafts)
        prefix_key, rest_key = haskey(node, "prefixItems") ? ("prefixItems", "items") :
                               items isa AbstractVector ? ("items", "additionalItems") : ("", "")
        if !isempty(prefix_key)
            prefix = node[prefix_key]
            # a Julia tuple has no optional elements, so all of them must be required
            get(node, "minItems", 0) >= length(prefix) || return TypeRef("Vector{Any}"), constraints
            elems = TypeRef[first(resolve_type(gen, file, pointer * "/$prefix_key/" * string(i - 1), sub, depth + 1))
                            for (i, sub) in enumerate(prefix)]
            exprs = [e.expr for e in elems]
            deps = unique(reduce(vcat, [e.deps for e in elems]; init = String[]))
            rest = get(node, rest_key, true)
            if rest === true || (isobject(rest) && isempty(rest))
                push!(exprs, "Vararg{Any}")
            elseif isobject(rest)
                t, _ = resolve_type(gen, file, pointer * "/" * rest_key, rest, depth + 1)
                push!(exprs, "Vararg{$(t.expr)}")
                append!(deps, t.deps)
            end
            return TypeRef("Tuple{" * join(exprs, ", ") * "}", unique(deps)), constraints
        end
        if isobject(items)
            t, _ = resolve_type(gen, file, pointer * "/items", items, depth + 1)
            return TypeRef("Vector{$(t.expr)}", t.deps), constraints
        end
        return TypeRef("Vector{Any}"), constraints
    elseif jtype == "object"
        key = haskey(node, "additionalProperties") ? "additionalProperties" : "unevaluatedProperties"
        ap = get(node, key, nothing)
        # with `patternProperties`, values are kept as they are and checked against the schemas
        if isobject(ap) && !haskey(node, "patternProperties")
            t, _ = resolve_type(gen, file, pointer * "/" * key, ap, depth + 1)
            return TypeRef("Dict{String, $(t.expr)}", t.deps), constraints
        end
        return TypeRef("Dict{String, Any}"), constraints
    elseif jtype == "string" && gen.typed_formats && haskey(FORMAT_TYPES, get(node, "format", nothing))
        gen.used_formats = true
        return TypeRef(FORMAT_TYPES[node["format"]]), constraints
    elseif jtype isa AbstractString && haskey(PRIMITIVE_TYPES, jtype)
        return TypeRef(PRIMITIVE_TYPES[jtype]), constraints
    end
    return TypeRef("Any"), constraints
end

# The type of a generated type in field types: structs are parametrized by the integer and
# other numeric types, `I` and `T`, of the struct that contains them.
function named_typeref(gen::Generator, name::String)
    def = gen.types[gen.taken[name]]
    return TypeRef(def isa ObjectDef ? "$name{%I%, %T%}" : name, [name])
end

# The numeric types replaced by the default ones, `Int64` and `Float64`, and parametric
# structs by their `UnionAll` types (whose constructors use these defaults).
function default_numbers(expr::String)
    m = match(r"^([A-Za-z_][A-Za-z0-9_]*)\{%I%, %T%\}$", expr)
    m === nothing || return String(m[1])
    return replace(expr, "%I%" => "Int64", "%T%" => "Float64")
end

# Names for the numeric type parameters, `I` and `T` unless they clash with `taken` names.
function parameter_names(taken)
    pI, pT, k = "I", "T", 1
    while pI in taken || pT in taken
        pI, pT, k = "I$k", "T$k", k + 1
    end
    return pI, pT
end

function union_typeref(options::Vector{TypeRef})
    exprs = unique([o.expr for o in options])
    deps = unique(reduce(vcat, [o.deps for o in options]; init = String[]))
    "Any" in exprs && return TypeRef("Any", deps)
    length(exprs) == 1 && return TypeRef(only(exprs), deps)
    # put `Nothing` first, for readability
    sort!(exprs; by = e -> e == "Nothing" ? 0 : 1)
    return TypeRef("Union{" * join(exprs, ", ") * "}", deps)
end

function make_optional(t::TypeRef)
    t.expr == "Any" && return t
    if startswith(t.expr, "Union{")
        occursin(r"^Union\{Nothing,", t.expr) && return t
        return TypeRef("Union{Nothing, " * t.expr[7:end], t.deps)
    end
    t.expr == "Nothing" && return t
    return TypeRef("Union{Nothing, $(t.expr)}", t.deps)
end

"""
    generate_named_type!(gen, file, pointer, node) -> String

Generate (once) the struct or enum type for the subschema at the given location and return
its name.
"""
function generate_named_type!(gen::Generator, file::String, pointer::String, node)
    loc = location(file, pointer)
    haskey(gen.names, loc) && return gen.names[loc]
    name = register_name!(gen, file, pointer)

    if haskey(node, "enum") || haskey(node, "const")
        values = haskey(node, "enum") ? collect(Any, node["enum"]) : Any[node["const"]]
        gen.types[loc] = EnumDef(name, loc, type_description(node),
                                 values, enum_valuetype(values))
        return name
    end

    props, required, merged = merge_allof(gen, file, pointer, node)
    if isempty(props) && (haskey(merged, "enum") || haskey(merged, "const"))
        values = haskey(merged, "enum") ? collect(Any, merged["enum"]) : Any[merged["const"]]
        gen.types[loc] = EnumDef(name, loc, type_description(node),
                                 values, enum_valuetype(values))
        return name
    end
    # After merging `allOf`, the properties of the merged schema are exactly the ones a
    # validator counts as evaluated, so `unevaluatedProperties` (JSON Schema 2019-09 and
    # later) acts on the merged type like `additionalProperties`.
    # That is only exact when no other keyword can evaluate properties (`anyOf`, `if`,
    # `additionalProperties` in a subschema...); otherwise the struct is left open and the
    # whole schema is checked at runtime.
    simple = simple_composition(gen, file, pointer, node)
    exact = simple && !any(k -> haskey(node, k), ("anyOf", "oneOf", "if", "dependentSchemas",
                                                    "dependencies", "patternProperties"))
    uneval_at_runtime = haskey(node, "unevaluatedProperties") && !haskey(node, "additionalProperties") && !exact
    extra_schema = uneval_at_runtime ? "" :
                   haskey(merged, "unevaluatedProperties") && !haskey(merged, "additionalProperties") ?
                   "unevaluatedProperties" : "additionalProperties"
    # (`additionalProperties`, when present, evaluates all the other properties)
    additional = uneval_at_runtime || (haskey(merged, "additionalProperties") ?
                                       merged["additionalProperties"] !== false :
                                       get(merged, "unevaluatedProperties", true) !== false)
    objdef = ObjectDef(name, loc, type_description(merged), FieldDef[],
                       additional, nothing, TypeRef("Any"),
                       get(merged, "minProperties", nothing), get(merged, "maxProperties", nothing),
                       nothing)
    # registered before generating the fields, so that recursive schemas terminate
    gen.types[loc] = objdef

    used = Set{String}()
    for (key, f, p, sub) in props
        t, c = resolve_type(gen, f, p, sub)
        nullable = t.expr in ("Nothing", "Any") || startswith(t.expr, "Union{Nothing,")
        is_required = key in required
        is_required || (t = make_optional(t))
        fname = field_identifier(key)
        while fname in used
            fname *= "_"
        end
        push!(used, fname)
        desc = isobject(sub) ? string(get(sub, "description", "")) : ""
        deprecated = isobject(sub) && get(sub, "deprecated", false) === true
        if isempty(desc) && isobject(sub) && haskey(sub, "\$ref")
            f2, p2 = resolve_ref(gen, f, sub["\$ref"], p)
            target = get_node(gen, f2, p2)
            isobject(target) && (desc = string(get(target, "description", "")))
        end
        r = field_residual(gen, f, p, sub)
        if r !== nothing
            c = c === nothing ? Dict{String, Any}() : copy(c)
            c["schema"] = r
        end
        default = is_required || !gen.use_defaults ? nothing : schema_default(gen, f, p, sub)
        push!(objdef.fields, FieldDef(fname, key, t, is_required, nullable, c, desc, deprecated, default))
    end
    objdef.schema = object_residual(gen, file, pointer, node)
    if uneval_at_runtime || !simple
        # the struct does not capture the schema exactly: check all of it at runtime
        objdef.schema = combine_residuals(Any[objdef.schema, translate_schema(gen, file, node; pointer)])
    end
    if haskey(merged, "patternProperties")
        # properties matching a pattern are kept in the extra field and checked against
        # their schemas, along with the other additional properties
        objdef.schema = combine_residuals(Any[objdef.schema, Dict{String, Any}(
            "properties" => Dict{String, Any}(f.key => true for f in objdef.fields),
            "patternProperties" => translate_schema(gen, file, merged["patternProperties"]; kind = :map),
            "additionalProperties" => translate_schema(gen, file, get(merged, extra_schema, true)),
        )])
        additional = true
        extra_schema = ""
    end
    if additional
        # properties not described by the schema are kept in an extra field
        fname = "_extra"
        while fname in used
            fname *= "_"
        end
        objdef.extra_field = fname
        ap = get(node, extra_schema, nothing)
        if isobject(ap) && !isempty(extra_schema)
            objdef.extra_type, _ = resolve_type(gen, file, pointer * "/" * extra_schema, ap)
        end
    end
    return name
end

# keywords of the subschemas of an `allOf` (or `$ref`) that the merged struct captures exactly
simple_member_key(k) = k in ("type", "properties", "required", "allOf", "\$ref", "\$dynamicAnchor") ||
                       k in OBJECT_RESIDUAL_KEYS || k in ANNOTATION_KEYS

"""
    simple_composition(gen, file, pointer, node)

Whether the struct merged from `node` and the subschemas it combines with `allOf` and `\$ref`
captures them exactly: each subschema only declares properties (and keywords checked on
the whole object), and `additionalProperties`, which does not see the properties of the
subschemas, is not used next to them. Otherwise the whole schema is also checked at runtime.
"""
function simple_composition(gen::Generator, file::String, pointer::String, node)
    (haskey(node, "allOf") || haskey(node, "\$ref")) || return true
    haskey(node, "additionalProperties") && return false
    function simple(f, p, n, d)
        d > 32 && return false
        n === true && return true
        isobject(n) || return false
        all(simple_member_key, keys(n)) || return false
        get(n, "type", "object") == "object" || return false
        if haskey(n, "\$ref")
            f2, p2 = resolve_ref(gen, f, n["\$ref"], p)
            simple(f2, p2, get_node(gen, f2, p2), d + 1) || return false
        end
        for (i, sub) in enumerate(get(n, "allOf", ()))
            simple(f, p * "/allOf/" * string(i - 1), sub, d + 1) || return false
        end
        return true
    end
    for (i, sub) in enumerate(get(node, "allOf", ()))
        simple(file, pointer * "/allOf/" * string(i - 1), sub, 1) || return false
    end
    if haskey(node, "\$ref")
        f2, p2 = resolve_ref(gen, file, node["\$ref"], pointer)
        simple(f2, p2, get_node(gen, f2, p2), 1) || return false
    end
    return true
end

# The `default` of a property schema, or of the schema it references.
function schema_default(gen::Generator, file::String, pointer::String, node, depth::Int = 0)
    (isobject(node) && depth <= 32) || return nothing
    haskey(node, "default") && return Some(node["default"])
    if haskey(node, "\$ref")
        f, p = resolve_ref(gen, file, node["\$ref"], pointer)
        return schema_default(gen, f, p, get_node(gen, f, p), depth + 1)
    end
    return nothing
end

# Description of a type, flagged when the schema marks it as deprecated.
function type_description(node)
    desc = string(get(node, "description", ""))
    get(node, "deprecated", false) === true || return desc
    return isempty(desc) ? "**Deprecated.**" : "**Deprecated.** " * desc
end

function enum_valuetype(values)
    all(v -> v isa AbstractString, values) && return "String"
    all(v -> v isa Integer && !(v isa Bool), values) && return "Int64"
    all(v -> v isa Real && !(v isa Bool), values) && return "Float64"
    all(v -> v isa Bool, values) && return "Bool"
    return "Any"
end

# --- Keywords not enforced by the Julia types ---
#
# Some keywords cannot be expressed by the generated types: `not`, `if`/`then`/`else`,
# `format`, `patternProperties`, `dependentRequired`, `contains`..., and the exclusivity of
# `oneOf` (and the constraints of the options of `oneOf`/`anyOf`, since a `Union` only
# checks their types). These "residual" subschemas are embedded in the generated code,
# with their `$ref`s resolved, and checked at runtime against the JSON form of the values.

# keywords whose value is a subschema, a list of subschemas, or a map to subschemas
const SCHEMA_KEYS = ("not", "if", "then", "else", "items", "additionalItems", "contains",
                     "propertyNames", "additionalProperties", "unevaluatedProperties",
                     "unevaluatedItems")
const SCHEMA_LIST_KEYS = ("allOf", "anyOf", "oneOf", "prefixItems")
const SCHEMA_MAP_KEYS = ("properties", "patternProperties", "dependentSchemas")
const ANNOTATION_KEYS = ("title", "description", "examples", "default", "deprecated",
                         "readOnly", "writeOnly", "\$comment", "\$schema", "\$id",
                         "\$anchor", "definitions", "\$defs", "contentMediaType",
                         "contentEncoding")

# keywords always left to the runtime validator, for fields and for objects
const FIELD_RESIDUAL_KEYS = ("not", "if", "then", "else", "format", "contains", "minContains",
                             "maxContains", "propertyNames", "dependentRequired",
                             "dependentSchemas", "dependencies", "prefixItems", "required")
const OBJECT_RESIDUAL_KEYS = ("not", "if", "then", "else", "propertyNames", "anyOf", "oneOf",
                              "dependentRequired", "dependentSchemas", "dependencies")

"""
    translate_schema(gen, file, node; kind = :schema) -> Any

Copy of the subschema `node` (found in `file`) for validation at runtime: annotations are
dropped, a `\$ref` to a schema translated into a generated type `T` becomes
`{"\$type": "T"}` (checked by converting the value to `T`), and other `\$ref`s are replaced
by the subschemas they point to (a reference back to a subschema being translated is
dropped, i.e. accepted).
"""
function translate_schema(gen::Generator, file::String, node, visiting = Set{String}();
                          kind = :schema, pointer::String = "")
    sub(p, k) = p * "/" * escape_pointer_segment(string(k))
    if kind == :list
        return Any[translate_schema(gen, file, n, visiting; pointer = sub(pointer, i - 1))
                   for (i, n) in enumerate(node)]
    elseif kind == :map
        return Dict{String, Any}(String(k) => translate_schema(gen, file, v, visiting; pointer = sub(pointer, k))
                                 for (k, v) in node)
    end
    isobject(node) || return node
    out = Dict{String, Any}()
    for (k, v) in node
        (k in ANNOTATION_KEYS || k == "\$ref") && continue
        p = sub(pointer, k)
        out[k] = if k in SCHEMA_KEYS
            translate_schema(gen, file, v, visiting; kind = v isa AbstractVector ? :list : :schema, pointer = p)
        elseif k in SCHEMA_LIST_KEYS
            translate_schema(gen, file, v, visiting; kind = :list, pointer = p)
        elseif k in SCHEMA_MAP_KEYS
            translate_schema(gen, file, v, visiting; kind = :map, pointer = p)
        elseif k == "dependencies"
            Dict{String, Any}(String(d) => x isa AbstractVector ? collect(Any, x) :
                                           translate_schema(gen, file, x, visiting; pointer = sub(p, d))
                              for (d, x) in v)
        else
            v isa AbstractVector ? collect(Any, v) : isobject(v) ? Dict{String, Any}(v) : v
        end
    end
    if haskey(node, "\$ref")
        f, p = resolve_ref(gen, file, node["\$ref"], pointer)
        loc = location(f, p)
        target_node = get_node(gen, f, p)
        if needs_named_type(gen, f, p, target_node)
            target = Dict{String, Any}("\$type" => generate_named_type!(gen, f, p, target_node))
        elseif !(loc in visiting)
            target = translate_schema(gen, f, target_node, union(visiting, [loc]); pointer = p)
        else
            target = nothing
        end
        target === nothing || (out["allOf"] = push!(get(out, "allOf", Any[]), target))
    end
    # a lone `{"allOf": [x]}` is just `x`
    if length(out) == 1 && haskey(out, "allOf") && length(out["allOf"]) == 1
        return only(out["allOf"])
    end
    return out
end

# Translation of an option of `oneOf`/`anyOf` of a property: inline objects and enums are
# generated types, which are checked as such.
function translate_option(gen::Generator, file::String, pointer::String, node)
    needs_named_type(gen, file, pointer, node) &&
        return Dict{String, Any}("\$type" => generate_named_type!(gen, file, pointer, node))
    return translate_schema(gen, file, node)
end

function combine_residuals(parts::Vector)
    parts = filter(!isnothing, parts)
    isempty(parts) && return nothing
    length(parts) == 1 && return only(parts)
    return Dict{String, Any}("allOf" => parts)
end

# Whether a subschema that is not a generated type is checked as a whole at runtime: when it
# has no `type` (so its Julia type is `Any`), or combines subschemas in ways that the
# Julia type does not capture (`allOf`, or `oneOf`/`anyOf` next to other keywords).
function whole_at_runtime(node)
    isobject(node) || return false
    validation = [k for k in keys(node) if !(k in ANNOTATION_KEYS)]
    isempty(validation) && return false
    haskey(node, "allOf") && return true
    if haskey(node, "oneOf") || haskey(node, "anyOf")
        return any(k -> !(k in ("oneOf", "anyOf")), validation)
    end
    return !haskey(node, "type") && !haskey(node, "\$ref") && !haskey(node, "enum") && !haskey(node, "const")
end

"""
    field_residual(gen, file, pointer, node) -> Union{Nothing, Dict}

Subschema with the keywords of the property schema `node` that are not enforced by the
type of the field and its constraints.
"""
function field_residual(gen::Generator, file::String, pointer::String, node, depth::Int = 0)
    node === false && return false     # the boolean schema `false`: no value is valid
    isobject(node) || return nothing
    depth > 32 && return nothing
    # named types check their own residual keywords
    needs_named_type(gen, file, pointer, node) && return nothing
    # `unevaluatedItems`/`unevaluatedProperties` depend on the annotations of all the other
    # keywords, so the whole subschema is checked at runtime
    if haskey(node, "unevaluatedItems") || haskey(node, "unevaluatedProperties") || whole_at_runtime(node)
        t = translate_schema(gen, file, node; pointer)
        return t isa AbstractDict && isempty(t) ? nothing : t
    end
    parts = Any[]
    if haskey(node, "\$ref")
        f, p = resolve_ref(gen, file, node["\$ref"], pointer)
        push!(parts, field_residual(gen, f, p, get_node(gen, f, p), depth + 1))
    end
    r = Dict{String, Any}()
    for key in ("oneOf", "anyOf")
        haskey(node, key) || continue
        r[key] = Any[translate_option(gen, file, pointer * "/$key/" * string(i - 1), sub)
                     for (i, sub) in enumerate(node[key])]
    end
    for k in FIELD_RESIDUAL_KEYS
        haskey(node, k) || continue
        v = node[k]
        kp = pointer * "/" * k
        r[k] = k in SCHEMA_KEYS ? translate_schema(gen, file, v; pointer = kp) :
               k == "prefixItems" ? translate_schema(gen, file, v; kind = :list, pointer = kp) :
               k == "dependentSchemas" ? translate_schema(gen, file, v; kind = :map, pointer = kp) :
               k == "dependencies" ? translate_schema(gen, file, Dict("dependencies" => v); pointer)["dependencies"] : v
    end
    items = get(node, "items", nothing)
    if isobject(items) && haskey(node, "prefixItems")
        r["items"] = translate_schema(gen, file, items; pointer = pointer * "/items")
    elseif isobject(items)
        ir = field_residual(gen, file, pointer * "/items", items, depth + 1)
        ir === nothing || (r["items"] = ir)
    elseif items isa AbstractVector
        r["items"] = translate_schema(gen, file, items; kind = :list, pointer = pointer * "/items")
        ai = get(node, "additionalItems", nothing)
        ai === nothing || (r["additionalItems"] = translate_schema(gen, file, ai; pointer = pointer * "/additionalItems"))
    elseif items === false && haskey(node, "prefixItems")
        r["items"] = false
    end
    if haskey(node, "patternProperties")
        r["patternProperties"] = translate_schema(gen, file, node["patternProperties"]; kind = :map,
                                                  pointer = pointer * "/patternProperties")
        apkey = haskey(node, "additionalProperties") ? "additionalProperties" : "unevaluatedProperties"
        ap = get(node, apkey, nothing)
        ap === nothing || (r[apkey] = translate_schema(gen, file, ap; pointer = pointer * "/" * apkey))
    else
        get(node, "additionalProperties", nothing) === false && (r["additionalProperties"] = false)
        for key in ("additionalProperties", "unevaluatedProperties")
            ap = get(node, key, nothing)
            isobject(ap) || continue
            ar = field_residual(gen, file, pointer * "/" * key, ap, depth + 1)
            ar === nothing || (r[key] = ar)
        end
    end
    isempty(r) || push!(parts, r)
    return combine_residuals(parts)
end

"""
    object_residual(gen, file, pointer, node) -> Union{Nothing, Dict}

Subschema with the keywords that apply to the object described by `node` as a whole and
are not enforced by its struct, collected from `node` and the schemas it combines with
`allOf` and `\$ref`.
"""
function object_residual(gen::Generator, file::String, pointer::String, node)
    parts = Any[]
    function walk(f, p, n, d)
        (isobject(n) && d <= 32) || return
        keys_ = [k for k in OBJECT_RESIDUAL_KEYS if haskey(n, k)]
        isempty(keys_) || push!(parts, translate_schema(gen, f, Dict{String, Any}(k => n[k] for k in keys_); pointer = p))
        if haskey(n, "\$ref")
            f2, p2 = resolve_ref(gen, f, n["\$ref"], p)
            walk(f2, p2, get_node(gen, f2, p2), d + 1)
        end
        for (i, sub) in enumerate(get(n, "allOf", ()))
            walk(f, p * "/allOf/" * string(i - 1), sub, d + 1)
        end
    end
    walk(file, pointer, node, 0)
    return combine_residuals(parts)
end

# --- Code emission ---

schema_file_of(d) = String(first(split(d.location, '#'; limit = 2)))

# Names of the generated types a struct depends on, through its fields.
type_deps(d::EnumDef) = String[]
type_deps(d::ObjectDef) = vcat([f.type.deps for f in d.fields]..., d.extra_type.deps)

"""
    group_types(gen) -> Vector{Pair{String, Vector{Union{ObjectDef, EnumDef}}}}

Group the generated types by the schema file that defines them and sort them so that every
type is defined before the types that use it, as far as possible.

Groups come in dependency order (a group only uses types from itself and from earlier
groups). Schema files whose types depend on each other in a cycle are merged into a single
group. Within a group, enums come first, then structs in depth-first dependency order.
Each group is named after its schema file(s).
"""
function group_types(gen::Generator)
    defs = [gen.types[loc] for loc in gen.order if haskey(gen.types, loc)]
    byname = Dict(d.name => d for d in defs)

    # dependency graph between schema files, in discovery order
    files = unique(schema_file_of.(defs))
    edges = Dict(f => String[] for f in files)
    for d in defs, dep in type_deps(d)
        f, g = schema_file_of(d), schema_file_of(byname[dep])
        f == g || g in edges[f] || push!(edges[f], g)
    end

    # strongly connected components (Tarjan); each one is emitted after the ones it uses
    index = Dict{String, Int}(); low = Dict{String, Int}()
    stack = String[]; onstack = Set{String}(); sccs = Vector{Vector{String}}()
    counter = Ref(0)
    function strongconnect(v)
        counter[] += 1
        index[v] = low[v] = counter[]
        push!(stack, v); push!(onstack, v)
        for w in edges[v]
            if !haskey(index, w)
                strongconnect(w)
                low[v] = min(low[v], low[w])
            elseif w in onstack
                low[v] = min(low[v], index[w])
            end
        end
        if low[v] == index[v]
            scc = String[]
            while true
                w = pop!(stack); delete!(onstack, w); push!(scc, w)
                w == v && break
            end
            push!(sccs, sort!(scc; by = f -> findfirst(==(f), files)))
        end
    end
    foreach(f -> haskey(index, f) || strongconnect(f), files)

    # sort the types within each group
    groups = Pair{String, Vector{Union{ObjectDef, EnumDef}}}[]
    taken = Set{String}()
    for scc in sccs
        members = Set(scc)
        ingroup = [d for d in defs if schema_file_of(d) in members]
        sorted = Union{ObjectDef, EnumDef}[d for d in ingroup if d isa EnumDef]
        state = Dict{String, Symbol}()
        function visit(d::ObjectDef)
            get(state, d.name, :new) == :new || return
            state[d.name] = :visiting
            for dep in type_deps(d)
                dd = byname[dep]
                dd isa ObjectDef && schema_file_of(dd) in members && visit(dd)
            end
            state[d.name] = :done
            push!(sorted, d)
        end
        foreach(d -> d isa ObjectDef && visit(d), ingroup)
        name = join([replace(splitext(basename(f))[1], r"[^A-Za-z0-9_.-]" => "_") for f in scc], "_and_")
        base = name; k = 2
        while name in taken
            name = base * "_" * string(k); k += 1
        end
        push!(taken, name)
        push!(groups, name => sorted)
    end
    return groups
end

function julia_literal(v)
    v isa AbstractString && return repr(String(v))
    v === nothing && return "nothing"
    v isa Bool && return string(v)
    v isa Integer && return string(Int64(v))
    v isa AbstractFloat && return repr(Float64(v))
    v isa AbstractVector && return "Any[" * join(julia_literal.(v), ", ") * "]"
    if isobject(v)
        return "Dict{String, Any}(" * join([repr(String(k)) * " => " * julia_literal(x) for (k, x) in v], ", ") * ")"
    end
    return repr(v)
end

# A schema for validation at runtime, as indented JSON, parsed when the module is loaded.
function schema_literal(schema, indent::String)
    schema === nothing && return "nothing"
    json = JSON.json(schema; pretty = true)
    lines = split(escape_docstring(json), '\n')
    return "JSON.parse(\"\"\"\n" * join(indent .* "    " .* lines, "\n") * "\n" * indent * "    \"\"\")"
end

function constraints_literal(c)
    c === nothing && return "nothing"
    parts = String[]
    for k in sort!(collect(keys(c)))
        v = c[k]
        lit = k == "pattern" ? "_jsregex($(repr(String(v))))" :
              k == "items" ? constraints_literal(v) : julia_literal(v)
        k == "schema" && (lit = schema_literal(v, "        "))
        push!(parts, "$k = $lit")
    end
    return "(" * join(parts, ", ") * ",)"
end

function emit_enum(io::IO, d::EnumDef)
    println(io, "\"\"\"")
    println(io, "    ", d.name, "(value)")
    println(io)
    isempty(d.description) || (println(io, escape_docstring(d.description)); println(io))
    println(io, "Allowed values: ", escape_docstring(join(["`$(julia_literal(v))`" for v in d.values], ", ")), ".")
    println(io, "\"\"\"")
    println(io, "struct ", d.name, " <: AbstractSchemaEnum")
    println(io, "    value::", d.valuetype)
    println(io, "    ", d.name, "(value) = new(_jscheckenum(", d.name, ", _jsfrom(", d.valuetype, ", value)))")
    println(io, "end")
    # the allowed values, as a constant tuple (fast to check), also recorded in `_SPECS`
    println(io, "const _VALUES_", d.name, " = (", join(julia_literal.(d.values), ", "), length(d.values) == 1 ? ",)" : ")")
    println(io, "_enumvalues(::Type{", d.name, "}) = _VALUES_", d.name)
    println(io, "_SPECS[", d.name, "] = (values = _VALUES_", d.name, ",)")
    println(io)
end

function emit_struct(io::IO, d::ObjectDef, defined::Set{String})
    # The type parameters are named `I` and `T`, unless the struct is named so or uses a type
    # named so; in the constructors, whose arguments are named after the fields, they must
    # not clash with the field names either.
    extra = d.extra_field
    allfields = vcat([f.name for f in d.fields], extra === nothing ? String[] : [extra])
    typenames = Set([d.name; [dep for f in d.fields for dep in f.type.deps]; d.extra_type.deps])
    sI, sT = parameter_names(typenames)
    pI, pT = parameter_names(union(typenames, allfields))
    subs(expr) = replace(expr, "%I%" => sI, "%T%" => sT)
    # In the constructors, types named like a field (an argument there) are qualified with
    # the module, e.g. `(@__MODULE__).Color`, so that the argument does not hide them.
    hidden = intersect(typenames, allfields)
    function qualify(expr)
        for n in hidden
            expr = replace(expr, Regex("(?<![A-Za-z0-9_.])" * n * "(?![A-Za-z0-9_])") => "(@__MODULE__)." * n)
        end
        return expr
    end
    sub(expr) = qualify(replace(expr, "%I%" => pI, "%T%" => pT))
    self = d.name in allfields ? "(@__MODULE__)." * d.name : d.name

    # docstring
    println(io, "\"\"\"")
    println(io, "    ", d.name, "(; kwargs...)")
    println(io, "    ", d.name, "{$sI, $sT}(; kwargs...)")
    println(io)
    isempty(d.description) || (println(io, escape_docstring(d.description)); println(io))
    println(io, "Integers are stored as `$sI <: Integer` and other numbers as `$sT <: Real`; by default, `Int64`")
    println(io, "and `Float64`.")
    println(io)
    if !isempty(d.fields)
        println(io, "# Fields")
        println(io)
        for f in d.fields
            req = (f.required ? " (required)" : "") * (f.deprecated ? " (deprecated)" : "")
            keynote = f.name == f.key ? "" : " (JSON property `$(escape_docstring(f.key))`)"
            line = "- `$(f.name)::$(subs(f.type.expr))`$req$keynote"
            isempty(f.description) || (line *= ": " * escape_docstring(f.description))
            f.default === nothing ||
                (line *= (isempty(f.description) ? ": d" : " D") * "efaults to `" * escape_docstring(julia_literal(something(f.default))) * "`.")
            println(io, line)
        end
    end
    if extra !== nothing
        isempty(d.fields) && (println(io, "# Fields"); println(io))
        println(io, "- `$(extra)::Dict{String, $(subs(d.extra_type.expr))}`: additional properties, not described in the schema")
    end
    println(io, "\"\"\"")

    # struct definition
    params = "{$sI <: Integer, $sT <: Real}"
    println(io, "struct ", d.name, params, " <: AbstractSchemaObject")
    for f in d.fields
        # Types not yet defined (due to cyclic dependencies) are declared as `Any`;
        # the constructor still converts and checks them.
        declared = all(dep -> dep in defined || dep == d.name, f.type.deps) ? subs(f.type.expr) : "Any"
        declared == subs(f.type.expr) ||
            println(io, "    # declared as `Any` due to a cyclic dependency; actual type is `$(subs(f.type.expr))`")
        println(io, "    ", f.name, "::", declared)
    end
    kwargs = [f.required ? f.name : f.name * " = " * (f.default === nothing ? "nothing" : julia_literal(something(f.default)))
              for f in d.fields]
    if extra !== nothing
        extra_type = all(dep -> dep in defined || dep == d.name, d.extra_type.deps) ? subs(d.extra_type.expr) : "Any"
        println(io, "    ", extra, "::Dict{String, ", extra_type, "}")
        push!(kwargs, extra * " = Dict{String, Any}()")
    end
    cparams = "{$pI <: Integer, $pT <: Real}"
    println(io, "    function ", d.name, "{$pI, $pT}(; ", join(kwargs, ", "), ") where ", cparams)
    for f in d.fields
        println(io, "        ", f.name, " = _jsfrom(", sub(f.type.expr), ", ", f.name, ")")
    end
    extra === nothing || println(io, "        ", extra, " = _jsfrom(Dict{String, ", sub(d.extra_type.expr), "}, ", extra, ")")
    vals = join([f.name for f in d.fields], ", ")
    println(io, "        _jscheck(", self, "{$pI, $pT}, (", vals, isempty(d.fields) || length(d.fields) > 1 ? "" : ",", "), ",
            something(extra, "nothing"), ")")
    println(io, "        return new(", join(vcat([f.name for f in d.fields], extra === nothing ? String[] : [extra]), ", "), ")")
    println(io, "    end")
    println(io, "end")
    # positional constructor, with the fields in order (as printed, and as used by
    # ConstructionBase.jl/Accessors.jl to rebuild a value)
    # (without parameters: the default `Int64` and `Float64` for keyword arguments, and the
    # numeric types of the arguments, if any, for positional ones)
    println(io, d.name, "(; kwargs...) = ", d.name, "{Int64, Float64}(; kwargs...)")
    if !isempty(allfields)
        args = join(allfields, ", ")
        println(io, d.name, "{$pI, $pT}(", args, ") where ", cparams, " = ",
                self, "{$pI, $pT}(; ", args, ")")
        println(io, d.name, "(", args, ") = ", self, "{_jsnumbertypes(", args, ")...}(; ", args, ")")
    end

    # metadata
    # (a constant, returned by a method specialized on the type, so the checks are type-stable)
    println(io, "const _SPEC_", d.name, " = (")
    println(io, "    fields = (")
    for f in d.fields
        println(io, "        (name = :", f.name, ", key = ", repr(f.key), ", required = ", f.required,
                ", nullable = ", f.nullable, ", constraints = ", constraints_literal(f.constraints), "),")
    end
    println(io, "    ),")
    println(io, "    additionalProperties = ", d.additional_properties, ",")
    println(io, "    extra = ", extra === nothing ? "nothing" : ":" * extra, ",")
    println(io, "    minProperties = ", something(d.min_properties, "nothing"), ",")
    println(io, "    maxProperties = ", something(d.max_properties, "nothing"), ",")
    println(io, "    schema = ", schema_literal(d.schema, "    "), ",")
    println(io, ")")
    println(io, "_specs(::Type{<:", d.name, "}) = _SPEC_", d.name)
    println(io, "_SPECS[", d.name, "] = _SPEC_", d.name)
    println(io)
end

"""
    generate_module(schema_file, output; root_name, module_name, schemas, split, type_names,
                    download, typed_formats, use_defaults) -> String

Read the JSON Schema in `schema_file` (and every schema file it references through
`\$ref`) and write to `output_file` a Julia module defining types for all the objects and
enums in the schema, together with functions to read and write JSON documents with them:

* `readjson(T, filename)` and `fromjson(T, string)` parse a JSON document into a value of
  type `T` (e.g. the root type), validating it against the schema;
* `writejson(filename, x)` and `tojson(x)` write a value back to JSON;
* `fromdict(T, x)` and `todict(x)` convert from/to parsed JSON values;
* `setfields(x; kwargs...)` returns a copy of a value with some fields changed.

The generated module only depends on JSON.jl.

References (`\$ref`) are resolved as URIs, against the base URI set by the enclosing
`\$id`s: JSON pointers, `\$id`s, `\$anchor`s, and paths relative to the file containing
them. Additional schema files that are only referenced by their `\$id` (e.g.
`https://example.com/address.schema.json`) can be given in `schemas`. Remote schemas are
downloaded only with `download = true` (or `download = url -> content`).

With `typed_formats = true`, strings with the formats `date`, `date-time` and `uuid` are
stored as `Dates.Date`, `Dates.DateTime` (in UTC) and `UUIDs.UUID`. With
`use_defaults = true`, optional fields default to the `default` given in the schema, instead
of `nothing`. Both are off by default, since documents are then written back in a different
form (normalized dates, defaults filled in).

The name of the root type is `root_name`, which defaults to the `title` of the schema or
else to the name of the schema file. The module name defaults to the root type name
followed by `Types`.

By default the whole module is written to the file `output`. With `split = true`, `output`
is a directory, and the module is split into several files in it, following the schema
files: `<module_name>.jl` defines the module and includes `runtime.jl` (the code for
reading, writing and validating) and one file per schema file, named after it, with the
types defined in that schema file (inline subschemas go with the type containing them).
Schema files whose types depend on each other in a cycle share a single file. Load the
module by including `<module_name>.jl`.

Type names are derived from the schema (see the README). Any of them can be chosen with
`type_names`, mapping the location of a subschema, as `"file.json#/json/pointer"` (or
`"#/json/pointer"` in the root schema file), to the name of its type, e.g.
`Dict("recipe.json#/definitions/RecipeType/properties/type" => "RecipeKind")`.

Returns the path of the file defining the module.
"""
function generate_module(
    schema_file::AbstractString, output_file::AbstractString;
    root_name::Union{Nothing, AbstractString} = nothing,
    module_name::Union{Nothing, AbstractString} = nothing,
    schemas::AbstractVector{<:AbstractString} = String[],
    split::Bool = false,
    type_names::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
    download::Union{Bool, Function} = false,
    typed_formats::Bool = false,
    use_defaults::Bool = false,
)
    root_file = abspath(normpath(schema_file))
    gen = Generator(root_file, "")
    gen.typed_formats = typed_formats
    gen.use_defaults = use_defaults
    gen.fetch = download === true ? download_schema : download === false ? nothing : download
    for (k, v) in type_names
        key = startswith(k, "#") ? basename(root_file) * k : String(k)
        occursin('#', key) || throw(ArgumentError("invalid key `$k` in `type_names`; " *
                                                  "use `\"file.json#/json/pointer\"`"))
        type_identifier(v) == v || throw(ArgumentError("`$v` in `type_names` is not a valid type name"))
        gen.overrides[key] = String(v)
    end
    root = load_schema!(gen, root_file)
    foreach(f -> load_schema!(gen, f), schemas)
    if root_name === nothing
        root_name = isobject(root) && haskey(root, "title") ? root["title"] :
                    splitext(basename(root_file))[1]
    end
    gen.root_name = type_identifier(root_name)
    module_name = module_name === nothing ? gen.root_name * "Types" : type_identifier(module_name)

    root_type, root_constraints = resolve_type(gen, root_file, "", root)
    # the constraints and runtime-checked keywords of a root that is not a generated type
    # (e.g. `{"type": "array", "maxItems": 2}`) are checked when reading a document
    root_residual = field_residual(gen, root_file, "", root)
    if root_residual !== nothing
        root_constraints = root_constraints === nothing ? Dict{String, Any}() : copy(root_constraints)
        root_constraints["schema"] = root_residual
    end
    for k in setdiff(keys(gen.overrides), gen.used_overrides)
        @warn "`type_names` entry `$k` does not name a generated type; it was ignored"
    end

    files = generate_files(gen, module_name, root_type, basename(schema_file), split; root_constraints)
    if split
        mkpath(output_file)
        for (name, code) in files
            write(joinpath(output_file, name), code)
        end
        return joinpath(output_file, first(first(files)))
    end
    mkpath(dirname(abspath(output_file)))
    write(output_file, only(files)[2])
    return output_file
end

const GENERATED_NOTICE = "Do not edit it by hand: regenerate it instead."

"""
    generate_files(gen, module_name, root_type, schema_name, split) -> Vector{Pair{String, String}}

Generate the code of the module, as a list of `filename => code`, the main file first.
Without `split`, everything goes into the single main file.
"""
function generate_files(gen::Generator, module_name::String, root_type::TypeRef,
                        schema_name::String, split::Bool; root_constraints = nothing)
    groups = group_types(gen)
    names = [d.name for (_, ds) in groups for d in ds]
    if module_name in names
        # A module cannot define a type with its own name (an error in Julia < 1.12)
        throw(ArgumentError("the module name `$module_name` is also the name of a generated " *
                            "type; choose another `module_name` (e.g. `$(module_name)Types`)"))
    end
    main_file = module_name * ".jl"

    # code of each group
    defined = Set{String}()
    group_code = Pair{String, String}[]
    for (group, defs) in groups
        io = IOBuffer()
        for d in defs
            d isa EnumDef ? emit_enum(io, d) : emit_struct(io, d, defined)
            push!(defined, d.name)
        end
        filename = group * ".jl"
        while filename in (main_file, "runtime.jl", "runtime_formats.jl") || any(p -> p[1] == filename, group_code)
            filename = splitext(filename)[1] * "_types.jl"
        end
        push!(group_code, filename => String(take!(io)))
    end
    sources(group) = join(["`$(basename(f))`" for f in unique(schema_file_of.(last(groups[group])))], ", ")

    io = IOBuffer()
    println(io, "# This file was generated by JSONSchema2Types.jl from the JSON Schema")
    println(io, "# `", schema_name, "`. ", GENERATED_NOTICE)
    println(io)
    println(io, "module ", module_name)
    println(io)
    println(io, "using JSON")
    println(io)
    println(io, "export fromjson, tojson, readjson, writejson, fromdict, todict, setfields, check_formats!")
    println(io, "export AbstractSchemaObject, AbstractSchemaEnum, SchemaValidationError")
    for chunk in Iterators.partition(names, 6)
        println(io, "export ", join(chunk, ", "))
    end
    println(io, "export RootType")
    println(io)
    if split
        println(io, "include(\"runtime.jl\")")
        gen.used_formats && println(io, "include(\"runtime_formats.jl\")")
        println(io)
        println(io, "# Generated types, one file per schema file, in dependency order")
        for (filename, _) in group_code
            println(io, "include(", repr(filename), ")")
        end
    else
        print(io, RUNTIME_CODE)
        gen.used_formats && (println(io); print(io, FORMATS_CODE))
        for (i, (_, code)) in enumerate(group_code)
            println(io)
            println(io, "# ", "-"^87)
            println(io, "# Types from ", sources(i))
            println(io, "# ", "-"^87)
            println(io)
            print(io, code)
        end
    end
    println(io)
    println(io, "\"\"\"")
    println(io, "    RootType")
    println(io)
    root_expr = default_numbers(root_type.expr)
    if root_expr in names
        println(io, "Alias of `", root_expr, "`, the type of the root of the schema.")
    else
        println(io, "Type of the root of the schema.")
    end
    println(io, "\"\"\"")
    println(io, "const RootType = ", root_expr)
    if root_constraints !== nothing
        println(io)
        println(io, "# constraints on the root of the schema, checked when reading a document")
        println(io, "_ROOT_CONSTRAINTS[] = ", constraints_literal(root_constraints))
    end
    println(io)
    println(io, "end # module ", module_name)
    files = [main_file => String(take!(io))]
    split || return files

    included = "# This file is included by `$main_file`, generated by JSONSchema2Types.jl from the JSON\n" *
                     "# Schema `$schema_name`. $GENERATED_NOTICE\n"
    push!(files, "runtime.jl" => included * "\n" * RUNTIME_CODE)
    gen.used_formats && push!(files, "runtime_formats.jl" => included * "\n" * FORMATS_CODE)
    for (i, (filename, code)) in enumerate(group_code)
        push!(files, filename => included * "#\n# Types from " * sources(i) * ".\n\n" * code)
    end
    return files
end
