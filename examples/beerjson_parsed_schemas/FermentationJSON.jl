module FermentationJSON

"""
    mutable struct Struct5462

Fields:
   `FermentationProcedureType`: FermentationProcedureType defines the procedure for performing fermentation.
"""
mutable struct Struct5462
    FermentationProcedureType::Union{Nothing,FermentationProcedureType}
end

"""
    mutable struct FermentationProcedureType

FermentationProcedureType defines the procedure for performing fermentation.
"""
mutable struct FermentationProcedureType
    name::String
    description::Union{Nothing,String}
    notes::Union{Nothing,String}
    fermentation_steps::Vector{NoType}
end

end # module FermentationJSON