module BoilJSON

"""
    mutable struct Struct3550

Fields:
   `BoilProcedureType`: BoilProcedureType defines the procedure for performing a boil. A boil procedure with no steps is the same as a standard single step boil.
"""
mutable struct Struct3550
    BoilProcedureType::Union{Nothing,BoilProcedureType}
end

"""
    mutable struct BoilProcedureType

BoilProcedureType defines the procedure for performing a boil. A boil procedure with no steps is the same as a standard single step boil.
"""
mutable struct BoilProcedureType
    name::Union{Nothing,String}
    description::Union{Nothing,String}
    notes::Union{Nothing,String}
    pre_boil_size::Union{Nothing,VolumeType}
    boil_time::TimeType
    boil_steps::Union{Nothing,Vector{NoType}}
end

end # module BoilJSON