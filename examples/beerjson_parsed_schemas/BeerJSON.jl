module BeerJSON

"""
    mutable struct Struct9447

Fields:
   `beerjson`: Root element of all beerjson documents.
"""
mutable struct Struct9447
    beerjson::Beerjson
end

"""
    mutable struct Beerjson

Root element of all beerjson documents.

Fields:
   `version`: Explicitly encode beerjson version within list of records.
   `fermentables`: Records for any ingredient that contributes to the gravity of the beer.
   `miscellaneous_ingredients`: Records for adjuncts which do not contribute to the gravity of the beer.
   `hop_varieties`: Records detailing the many properties of unique hop varieties.
   `cultures`: Records detailing the wide array of unique cultures.
   `profiles`: Records for water profiles used in brewing.
   `styles`: Records detailing the characteristics of the beer styles for which judging guidelines have been established.
   `mashes`: A collection of steps providing process information for common mashing procedures.
   `fermentations`: A collection of steps providing process information for common fermentation procedures.
   `recipes`: Records containing a minimal collection of the description of ingredients, procedures and other required parameters necessary to recreate a batch of beer.
   `equipments`: Provides necessary information for brewing equipment.
   `boil`: A collection of steps providing process information for common boil procedures.
   `packaging`: A collection of steps providing process information for common packaging procedures.
"""
mutable struct Beerjson
    version::Ref
    fermentables::Union{Nothing,Vector{NoType}}
    miscellaneous_ingredients::Union{Nothing,Vector{NoType}}
    hop_varieties::Union{Nothing,Vector{NoType}}
    cultures::Union{Nothing,Vector{NoType}}
    profiles::Union{Nothing,Vector{NoType}}
    styles::Union{Nothing,Vector{NoType}}
    mashes::Union{Nothing,Vector{NoType}}
    fermentations::Union{Nothing,Vector{NoType}}
    recipes::Union{Nothing,Vector{NoType}}
    equipments::Union{Nothing,Vector{NoType}}
    boil::Union{Nothing,Vector{NoType}}
    packaging::Union{Nothing,Vector{NoType}}
end

end # module BeerJSON