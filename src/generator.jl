# ---------------------------------------------------------------------------------------
# Generation of Julia types from JSON Schemas
# ---------------------------------------------------------------------------------------

const RUNTIME_FILE = joinpath(@__DIR__, "runtime.jl")
include_dependency(RUNTIME_FILE)
const RUNTIME_CODE = read(RUNTIME_FILE, String)

const PRIMITIVE_TYPES = Dict(
    "string" => "String",
    "number" => "Float64",
    "integer" => "Int64",
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
    ids::Dict{String, String}                      # `$id` => absolute path
    types::Dict{String, Union{ObjectDef, EnumDef}} # location => definition
    names::Dict{String, String}                    # location => type name
    taken::Dict{String, String}                    # type name => location
    order::Vector{String}                          # locations in discovery order
end

Generator(root_file::String, root_name::String) = Generator(
    root_file, root_name, Dict{String, Any}(), Dict{String, String}(),
    Dict{String, Union{ObjectDef, EnumDef}}(),
    Dict{String, String}(), Dict{String, String}(), String[],
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
    load_schema!(gen, path)

Load (and cache) the JSON schema in the file `path`.
"""
function load_schema!(gen::Generator, path::AbstractString)
    path = abspath(normpath(path))
    haskey(gen.files, path) && return gen.files[path]
    isfile(path) || error("Schema file not found: $path")
    schema = JSON.parse(read(path, String))
    gen.files[path] = schema
    if isobject(schema)
        id = get(schema, "\$id", get(schema, "id", nothing))
        id isa AbstractString && (gen.ids[strip_fragment(id)] = path)
    end
    return schema
end

unescape_pointer_segment(s) = replace(percent_unescape(s), "~1" => "/", "~0" => "~")

function percent_unescape(s::AbstractString)
    occursin('%', s) || return String(s)
    out = IOBuffer()
    bytes = codeunits(s)
    n = length(bytes)
    j = 1
    while j <= n
        if bytes[j] == UInt8('%') && j + 2 <= n
            write(out, parse(UInt8, String(bytes[j+1:j+2]); base = 16))
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
    resolve_ref(gen, file, ref) -> (file, pointer)

Resolve the `\$ref` value `ref`, found in the schema file `file`.
"""
function resolve_ref(gen::Generator, file::String, ref::AbstractString)
    path, fragment = occursin('#', ref) ? split(ref, '#'; limit = 2) : (ref, "")
    if isempty(path)
        target = file
    elseif haskey(gen.ids, path)
        target = gen.ids[path]
    elseif occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", path)
        error("Cannot resolve `\$ref` to `$ref`: remote references are not fetched. Download " *
              "the schema and pass it with the `schemas` keyword argument, so that it is " *
              "found by its `\$id`, or use a relative path instead.")
    else
        target = abspath(normpath(joinpath(dirname(file), path)))
    end
    load_schema!(gen, target)
    fragment = String(fragment)
    if !isempty(fragment) && !startswith(fragment, "/")
        error("Only JSON pointer fragments are supported in `\$ref`: `$ref`")
    end
    return target, fragment
end

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
            base *= type_identifier(nxt)
            step = 2
        elseif seg == "allOf" && nxt !== nothing
            step = 2
        elseif seg in ("oneOf", "anyOf") && nxt !== nothing
            base *= "Option" * string(parse(Int, nxt) + 1)
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
    return base
end

"""
    register_name!(gen, file, pointer) -> String

Assign a unique type name to the subschema at the given location.
"""
function register_name!(gen::Generator, file::String, pointer::String)
    loc = location(file, pointer)
    haskey(gen.names, loc) && return gen.names[loc]
    hint = name_hint(gen, file, pointer)
    name = hint
    if haskey(gen.taken, name)
        name = type_identifier(splitext(basename(file))[1]) * hint
        k = 2
        while haskey(gen.taken, name)
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
function collect_constraints(gen::Generator, file::String, node)
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
    if get(node, "type", nothing) == "array" && isobject(get(node, "items", nothing))
        ic = item_constraints(gen, file, node["items"])
        ic !== nothing && (c["items"] = ic)
    end
    return isempty(c) ? nothing : c
end

# Constraints of array items: follow `$ref`s to primitive schemas.
function item_constraints(gen::Generator, file::String, node, depth::Int = 0)
    isobject(node) || return nothing
    if haskey(node, "\$ref") && depth < 32
        f, p = resolve_ref(gen, file, node["\$ref"])
        target = get_node(gen, f, p)
        needs_named_type(gen, f, p, target) && return nothing
        return item_constraints(gen, f, target, depth + 1)
    end
    isobject(node) && (haskey(node, "enum") || haskey(node, "const") || haskey(node, "properties")) && return nothing
    return collect_constraints(gen, file, node)
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
            f2, p2 = resolve_ref(gen, f, n["\$ref"])
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

    if haskey(node, "\$ref")
        f, p = resolve_ref(gen, file, node["\$ref"])
        target = get_node(gen, f, p)
        if needs_named_type(gen, f, p, target)
            name = generate_named_type!(gen, f, p, target)
            return TypeRef(name, [name]), nothing
        end
        t, c = resolve_type(gen, f, p, target, depth + 1)
        # constraints next to the `$ref` (ignored before draft 2019-09, but harmless)
        c2 = collect_constraints(gen, file, node)
        c2 !== nothing && (c = c === nothing ? c2 : merge(c, c2))
        return t, c
    end

    if needs_named_type(gen, file, pointer, node)
        name = generate_named_type!(gen, file, pointer, node)
        return TypeRef(name, [name]), nothing
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
        return union_typeref(options), collect_constraints(gen, file, node)
    end

    constraints = collect_constraints(gen, file, node)
    if jtype == "array"
        items = get(node, "items", nothing)
        if isobject(items)
            t, _ = resolve_type(gen, file, pointer * "/items", items, depth + 1)
            return TypeRef("Vector{$(t.expr)}", t.deps), constraints
        end
        return TypeRef("Vector{Any}"), constraints
    elseif jtype == "object"
        key = haskey(node, "additionalProperties") ? "additionalProperties" : "unevaluatedProperties"
        ap = get(node, key, nothing)
        if isobject(ap)
            t, _ = resolve_type(gen, file, pointer * "/" * key, ap, depth + 1)
            return TypeRef("Dict{String, $(t.expr)}", t.deps), constraints
        end
        return TypeRef("Dict{String, Any}"), constraints
    elseif jtype isa AbstractString && haskey(PRIMITIVE_TYPES, jtype)
        return TypeRef(PRIMITIVE_TYPES[jtype]), constraints
    end
    return TypeRef("Any"), constraints
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
    extra_schema = haskey(merged, "unevaluatedProperties") && !haskey(merged, "additionalProperties") ?
                   "unevaluatedProperties" : "additionalProperties"
    additional = get(merged, extra_schema, true) !== false &&
                 get(merged, "unevaluatedProperties", true) !== false
    objdef = ObjectDef(name, loc, type_description(merged), FieldDef[],
                       additional, nothing, TypeRef("Any"),
                       get(merged, "minProperties", nothing), get(merged, "maxProperties", nothing))
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
            f2, p2 = resolve_ref(gen, f, sub["\$ref"])
            target = get_node(gen, f2, p2)
            isobject(target) && (desc = string(get(target, "description", "")))
        end
        push!(objdef.fields, FieldDef(fname, key, t, is_required, nullable, c, desc, deprecated))
    end
    if additional
        # properties not described by the schema are kept in an extra field
        fname = "_extra"
        while fname in used
            fname *= "_"
        end
        objdef.extra_field = fname
        ap = get(node, extra_schema, nothing)
        if isobject(ap)
            objdef.extra_type, _ = resolve_type(gen, file, pointer * "/" * extra_schema, ap)
        end
    end
    return name
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

function constraints_literal(c)
    c === nothing && return "nothing"
    parts = String[]
    for k in sort!(collect(keys(c)))
        v = c[k]
        lit = k == "pattern" ? "Regex($(repr(String(v))))" :
              k == "items" ? constraints_literal(v) : julia_literal(v)
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
    println(io, "_SPECS[", d.name, "] = (values = ", "Any[", join(julia_literal.(d.values), ", "), "],)")
    println(io)
end

function emit_struct(io::IO, d::ObjectDef, defined::Set{String})
    # docstring
    println(io, "\"\"\"")
    println(io, "    ", d.name, "(; kwargs...)")
    println(io)
    isempty(d.description) || (println(io, escape_docstring(d.description)); println(io))
    if !isempty(d.fields)
        println(io, "# Fields")
        println(io)
        for f in d.fields
            req = (f.required ? " (required)" : "") * (f.deprecated ? " (deprecated)" : "")
            keynote = f.name == f.key ? "" : " (JSON property `$(escape_docstring(f.key))`)"
            line = "- `$(f.name)::$(f.type.expr)`$req$keynote"
            isempty(f.description) || (line *= ": " * escape_docstring(f.description))
            println(io, line)
        end
    end
    if d.extra_field !== nothing
        isempty(d.fields) && (println(io, "# Fields"); println(io))
        println(io, "- `$(d.extra_field)::Dict{String, $(d.extra_type.expr)}`: additional properties, not described in the schema")
    end
    println(io, "\"\"\"")

    # struct definition
    println(io, "struct ", d.name, " <: AbstractSchemaObject")
    for f in d.fields
        # Types not yet defined (due to cyclic dependencies) are declared as `Any`;
        # the constructor still converts and checks them.
        declared = all(dep -> dep in defined || dep == d.name, f.type.deps) ? f.type.expr : "Any"
        declared == f.type.expr || println(io, "    # declared as `Any` due to a cyclic dependency; actual type is `$(f.type.expr)`")
        println(io, "    ", f.name, "::", declared)
    end
    kwargs = [f.required ? f.name : f.name * " = nothing" for f in d.fields]
    extra = d.extra_field
    if extra !== nothing
        extra_type = all(dep -> dep in defined || dep == d.name, d.extra_type.deps) ? d.extra_type.expr : "Any"
        println(io, "    ", extra, "::Dict{String, ", extra_type, "}")
        push!(kwargs, extra * " = Dict{String, Any}()")
    end
    println(io, "    function ", d.name, "(; ", join(kwargs, ", "), ")")
    for f in d.fields
        println(io, "        ", f.name, " = _jsfrom(", f.type.expr, ", ", f.name, ")")
    end
    extra === nothing || println(io, "        ", extra, " = _jsfrom(Dict{String, ", d.extra_type.expr, "}, ", extra, ")")
    vals = join([f.name for f in d.fields], ", ")
    println(io, "        _jscheck(", d.name, ", (", vals, isempty(d.fields) || length(d.fields) > 1 ? "" : ",", "), ",
            something(extra, "nothing"), ")")
    println(io, "        return new(", join(vcat([f.name for f in d.fields], extra === nothing ? String[] : [extra]), ", "), ")")
    println(io, "    end")
    println(io, "end")

    # metadata
    println(io, "_SPECS[", d.name, "] = (")
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
    println(io, ")")
    println(io)
end

"""
    generate_module(schema_file, output; root_name, module_name, schemas, split) -> String

Read the JSON Schema in `schema_file` (and every schema file it references through
`\$ref`) and write to `output_file` a Julia module defining types for all the objects and
enums in the schema, together with functions to read and write JSON documents with them:

* `readjson(T, filename)` and `fromjson(T, string)` parse a JSON document into a value of
  type `T` (e.g. the root type), validating it against the schema;
* `writejson(filename, x)` and `tojson(x)` write a value back to JSON;
* `fromdict(T, x)` and `todict(x)` convert from/to parsed JSON values.

The generated module only depends on JSON.jl.

References (`\$ref`) are resolved relative to the file containing them, or by the `\$id`
of the loaded schemas. Additional schema files that are only referenced by their `\$id`
(e.g. `https://example.com/address.schema.json`) can be given in `schemas`. Remote
schemas are not downloaded.

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

Returns the path of the file defining the module.
"""
function generate_module(
    schema_file::AbstractString, output_file::AbstractString;
    root_name::Union{Nothing, AbstractString} = nothing,
    module_name::Union{Nothing, AbstractString} = nothing,
    schemas::AbstractVector{<:AbstractString} = String[],
    split::Bool = false,
)
    root_file = abspath(normpath(schema_file))
    gen = Generator(root_file, "")
    root = load_schema!(gen, root_file)
    foreach(f -> load_schema!(gen, f), schemas)
    if root_name === nothing
        root_name = isobject(root) && haskey(root, "title") ? root["title"] :
                    splitext(basename(root_file))[1]
    end
    gen.root_name = type_identifier(root_name)
    module_name = module_name === nothing ? gen.root_name * "Types" : type_identifier(module_name)

    root_type, _ = resolve_type(gen, root_file, "", root)

    files = generate_files(gen, module_name, root_type, basename(schema_file), split)
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
                        schema_name::String, split::Bool)
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
        while filename in (main_file, "runtime.jl") || any(p -> p[1] == filename, group_code)
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
    println(io, "export fromjson, tojson, readjson, writejson, fromdict, todict")
    println(io, "export AbstractSchemaObject, AbstractSchemaEnum, SchemaValidationError")
    for chunk in Iterators.partition(names, 6)
        println(io, "export ", join(chunk, ", "))
    end
    println(io, "export RootType")
    println(io)
    if split
        println(io, "include(\"runtime.jl\")")
        println(io)
        println(io, "# Generated types, one file per schema file, in dependency order")
        for (filename, _) in group_code
            println(io, "include(", repr(filename), ")")
        end
    else
        print(io, RUNTIME_CODE)
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
    if root_type.expr in names
        println(io, "Alias of `", root_type.expr, "`, the type of the root of the schema.")
    else
        println(io, "Type of the root of the schema.")
    end
    println(io, "\"\"\"")
    println(io, "const RootType = ", root_type.expr)
    println(io)
    println(io, "end # module ", module_name)
    files = [main_file => String(take!(io))]
    split || return files

    included = "# This file is included by `$main_file`, generated by JSONSchema2Types.jl from the JSON\n" *
                     "# Schema `$schema_name`. $GENERATED_NOTICE\n"
    push!(files, "runtime.jl" => included * "\n" * RUNTIME_CODE)
    for (i, (filename, code)) in enumerate(group_code)
        push!(files, filename => included * "#\n# Types from " * sources(i) * ".\n\n" * code)
    end
    return files
end
