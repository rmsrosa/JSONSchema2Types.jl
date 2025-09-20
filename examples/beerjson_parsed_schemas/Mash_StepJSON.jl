module Mash_StepJSON

"""
    mutable struct Struct5620

Fields:
   `MashStepType`: MashStepType - a per step representation occurring during the mash.
"""
mutable struct Struct5620
    MashStepType::Union{Nothing,MashStepType}
end

"""
    mutable struct MashStepType

MashStepType - a per step representation occurring during the mash.

Fields:
   `name`:
   `type`:
   `amount`:
   `step_temperature`:
   `step_time`:
   `ramp_time`: The amount of time  that passes before this step begins. eg moving from a mash step (step 1) of 148F, to a new temperature step of 156F (step 2) may take 8 minutes to heat the mash. Step 2 would have a ramp time of 8 minutes.
   `end_temperature`:
   `description`:
   `water_grain_ratio`: Also known as the mash thickness. eg 1.75 qt/lb or 3.65 L/kg.
   `infuse_temperature`: Temperature of the water for an infusion step.
   `start_ph`:
   `end_ph`:
"""
mutable struct MashStepType
    name::String
    type::String
    amount::Union{Nothing,VolumeType}
    step_temperature::TemperatureType
    step_time::TimeType
    ramp_time::Union{Nothing,TimeType}
    end_temperature::Union{Nothing,TemperatureType}
    description::Union{Nothing,String}
    water_grain_ratio::Union{Nothing,SpecificVolumeType}
    infuse_temperature::Union{Nothing,TemperatureType}
    start_ph::Union{Nothing,AcidityType}
    end_ph::Union{Nothing,AcidityType}
end

end # module Mash_StepJSON