module Fermentation_StepJSON

"""
    mutable struct Struct8158

Fields:
   `FermentationStepType`: FermentationStepType - a per step representation of a fermentation action.
"""
mutable struct Struct8158
    FermentationStepType::Union{Nothing,FermentationStepType}
end

"""
    mutable struct FermentationStepType

FermentationStepType - a per step representation of a fermentation action.

Fields:
   `name`:
   `description`:
   `start_temperature`:
   `end_temperature`:
   `step_time`:
   `free_rise`: Free rise is used to indicate a fermentation step where the exothermic fermentation is allowed to raise the temperature without restriction This is either True or false.
   `start_gravity`:
   `end_gravity`:
   `start_ph`:
   `end_ph`:
   `vessel`:
   `vessel_pressure`: Vessel pressure indicates the pressure applied within the fermentation vessel.
"""
mutable struct FermentationStepType
    name::String
    description::Union{Nothing,String}
    start_temperature::Union{Nothing,TemperatureType}
    end_temperature::Union{Nothing,TemperatureType}
    step_time::Union{Nothing,TimeType}
    free_rise::Union{Nothing,Bool}
    start_gravity::Union{Nothing,GravityType}
    end_gravity::Union{Nothing,GravityType}
    start_ph::Union{Nothing,AcidityType}
    end_ph::Union{Nothing,AcidityType}
    vessel::Union{Nothing,String}
    vessel_pressure::Union{Nothing,PressureType}
end

end # module Fermentation_StepJSON