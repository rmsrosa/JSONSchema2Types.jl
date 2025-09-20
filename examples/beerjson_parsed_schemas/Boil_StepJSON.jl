module Boil_StepJSON

"""
    mutable struct Struct5437

Fields:
   `BoilStepType`: BoilStepType - a per step representation of a boil process, can be used to support preboil steps, non-boiling pasteurization steps, boiling, whirlpool steps, and chilling.
"""
mutable struct Struct5437
    BoilStepType::Union{Nothing,BoilStepType}
end

"""
    mutable struct BoilStepType

BoilStepType - a per step representation of a boil process, can be used to support preboil steps, non-boiling pasteurization steps, boiling, whirlpool steps, and chilling.

Fields:
   `name`:
   `description`:
   `start_temperature`:
   `end_temperature`:
   `ramp_time`: The amount of time that passes before this step begins. eg moving from a boiling step (step 1) to a whirlpool step (step 2) may take 5 minutes. Step 2 would have a ramp time of 5 minutes, hop isomerization and bitterness calculations will need to account for this accordingly.
   `step_time`:
   `start_gravity`:
   `end_gravity`:
   `start_ph`:
   `end_ph`:
   `chilling_type`: Chilling type seperates batch chilling, eg immersion chillers, where the entire volume of wort is brought down in temperture as a whole, vs inline chilling where the wort is chilled while it is being drained, which can leave a significant amount of hop isomerization occuring in the boil kettle.
"""
mutable struct BoilStepType
    name::String
    description::Union{Nothing,String}
    start_temperature::Union{Nothing,TemperatureType}
    end_temperature::Union{Nothing,TemperatureType}
    ramp_time::Union{Nothing,TimeType}
    step_time::Union{Nothing,TimeType}
    start_gravity::Union{Nothing,GravityType}
    end_gravity::Union{Nothing,GravityType}
    start_ph::Union{Nothing,AcidityType}
    end_ph::Union{Nothing,AcidityType}
    chilling_type::Union{Nothing,String}
end

end # module Boil_StepJSON