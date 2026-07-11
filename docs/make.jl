# Build da documentação (Documenter.jl). Local:
#   julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# No CI, o workflow Documentation.yml publica em gh-pages automaticamente.

using DeBRief
using Documenter

DocMeta.setdocmeta!(DeBRief, :DocTestSetup, :(using DeBRief); recursive = true)

makedocs(
    modules = [DeBRief],
    authors = "Dante Bertuzzi and contributors",
    sitename = "DeBRief.jl",
    checkdocs = :exports,
    format = Documenter.HTML(
        canonical = "https://USERNAME.github.io/DeBRief.jl",
        edit_link = "main",
        prettyurls = get(ENV, "CI", "false") == "true",
    ),
    pages = [
        "Home" => "index.md",
        "Tutorial (beginners)" => "tutorial.md",
        "Guia rápido em português" => "guia_pt.md",
        "User guide" => "guide.md",
        "Data harmonization" => "harmonization.md",
        "API reference" => "reference.md",
    ],
)

deploydocs(repo = "github.com/USERNAME/DeBRief.jl", devbranch = "main")
