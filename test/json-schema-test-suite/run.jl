# Run the official JSON Schema Test Suite (https://github.com/json-schema-org/JSON-Schema-Test-Suite)
# against JSONSchema2Types, for the 2020-12 dialect, end to end: for each test case, a module
# is generated from the schema, and each test instance is read with `fromdict(RootType, data)`,
# which must succeed exactly when the instance is valid.
#
# Usage, from the root of the repository:
#
#     git clone --depth 1 https://github.com/json-schema-org/JSON-Schema-Test-Suite /path/to/suite
#     julia --project=. test/json-schema-test-suite/run.jl /path/to/suite [report.md] [--min-passed=N]
#
# Writes a report with the results by file (to `report.md`, if given) and prints a summary.
# With `--min-passed=N`, exits with an error if fewer than N tests pass (used in CI, with
# the number in `test/json-schema-test-suite/BASELINE`, to catch regressions).

using JSONSchema2Types
using JSON

const DIALECT = 2020
const METASCHEMA = "https://json-schema.org/draft/2020-12/schema"

# whether a test case applies to `version` (see the README of the test suite)
function compatible(compat, version = DIALECT)
    compat === nothing && return true
    valid = true
    for c in split(string(compat), ',')
        m = match(r"^(<=|=)?(\d+)$", strip(c))
        op, v = something(m[1], ""), parse(Int, m[2])
        valid = op == "" ? version >= v : op == "<=" ? version <= v : version == v
        version <= v && break
    end
    return valid
end

struct Outcome
    file::String
    case::String
    test::String
    expected::Bool
    result::Symbol   # :pass, :fail, :generror, :error
    message::String
end

function run_case(file, case)
    outcomes = Outcome[]
    dir = mktempdir()
    schema = case["schema"]
    if schema isa AbstractDict
        schema = Dict{String, Any}(schema)
        haskey(schema, "\$schema") || (schema["\$schema"] = METASCHEMA)
    end
    schema_file = joinpath(dir, "schema.json")
    write(schema_file, JSON.json(schema))
    external = Dict(String(k) => JSON.json(v) for (k, v) in get(case, "externalSchemas", Dict()))
    fetch(url) = haskey(external, url) ? external[url] : error("no external schema $url")
    tags = get(case, "tags", String[])
    M = try
        file_jl = generate_module(schema_file, joinpath(dir, "Generated.jl"); root_name = "Root",
                                  module_name = "Generated", download = fetch)
        Base.include(Module(), file_jl)
    catch err
        msg = first(sprint(showerror, err), 300)
        for t in case["tests"]
            push!(outcomes, Outcome(file, case["description"], t["description"], t["valid"], :generror, msg))
        end
        return outcomes
    end
    # the module was just defined: get its bindings in the latest world
    binding(name) = Base.invokelatest(getglobal, M, name)
    fromdict, RootType = binding(:fromdict), binding(:RootType)
    ValidationError = binding(:SchemaValidationError)
    Base.invokelatest(binding(:check_formats!), !("format-annotation" in tags))
    for t in case["tests"]
        result, msg = try
            Base.invokelatest(fromdict, RootType, t["data"])
            t["valid"] ? (:pass, "") : (:fail, "accepted an invalid instance")
        catch err
            if err isa ValidationError
                t["valid"] ? (:fail, "rejected a valid instance: " * err.msg) : (:pass, "")
            else
                (:error, first(sprint(showerror, err), 300))
            end
        end
        push!(outcomes, Outcome(file, case["description"], t["description"], t["valid"], result, first(msg, 300)))
    end
    return outcomes
end

function run_suite(suite; dirs = ["", "optional"])
    outcomes = Outcome[]
    for sub in dirs
        dir = joinpath(suite, "validation", "tests", sub)
        for f in sort(filter(endswith(".json"), readdir(dir)))
            name = isempty(sub) ? f : joinpath(sub, f)
            for case in JSON.parse(read(joinpath(dir, f), String))["tests"]
                compatible(get(case, "compatibility", nothing)) || continue
                append!(outcomes, run_case(name, case))
            end
        end
    end
    return outcomes
end

function report(io, outcomes)
    files = unique(o.file for o in outcomes)
    total = count(o -> o.result == :pass, outcomes)
    println(io, "# JSON Schema Test Suite (2020-12)\n")
    println(io, "Passed $total of $(length(outcomes)) tests.\n")
    println(io, "| File | Passed | Failed | Not generated | Errors |")
    println(io, "|---|---|---|---|---|")
    for f in files
        os = filter(o -> o.file == f, outcomes)
        c(r) = count(o -> o.result == r, os)
        println(io, "| $f | $(c(:pass))/$(length(os)) | $(c(:fail)) | $(c(:generror)) | $(c(:error)) |")
    end
    println(io, "\n## Failures\n")
    for o in outcomes
        o.result == :pass && continue
        println(io, "- **$(o.file)** / $(o.case) / $(o.test) (`$(o.result)`): ", replace(o.message, "\n" => " "))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    options = filter(startswith("--"), ARGS)
    paths = filter(!startswith("--"), ARGS)
    outcomes = run_suite(paths[1])
    if length(paths) >= 2
        open(io -> report(io, outcomes), paths[2], "w")
    end
    passed = count(o -> o.result == :pass, outcomes)
    println("Passed $passed of $(length(outcomes)) tests")
    for r in (:fail, :generror, :error)
        println("  $r: ", count(o -> o.result == r, outcomes))
    end
    for o in options
        m = match(r"^--min-passed=(\d+)$", o)
        m === nothing && continue
        if passed < parse(Int, m[1])
            println("Fewer tests passed than the baseline of $(m[1])")
            exit(1)
        end
    end
end
