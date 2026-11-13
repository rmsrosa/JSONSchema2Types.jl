# Build the documentation with
#
#     julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#     julia --project=docs docs/make.jl
#
# from the root of the repository. The pages are written to `docs/build/`.

using Documenter
using JSONSchema2Types

DocMeta.setdocmeta!(JSONSchema2Types, :DocTestSetup, :(using JSONSchema2Types); recursive = true)

makedocs(
    sitename = "JSONSchema2Types.jl",
    modules = [JSONSchema2Types],
    authors = "Ricardo Rosa",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://rmsrosa.github.io/JSONSchema2Types.jl",
        edit_link = "main",
        size_threshold_warn = 400 * 1024,
        size_threshold = 800 * 1024,
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => "guide.md",
        "Examples" => "examples.md",
        "BeerJSON" => "beerjson.md",
        "API" => "api.md",
    ],
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/rmsrosa/JSONSchema2Types.jl.git",
    devbranch = "main",
    push_preview = false,
)
