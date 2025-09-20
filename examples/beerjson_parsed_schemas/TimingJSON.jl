module TimingJSON

"""
    mutable struct Struct5216

Fields:
   `UseType`: Differentiates the specific process type when this ingredient addition is used.
   `TimingType`: The timing object fully describes the timing of an addition with options for basis on time, gravity, or pH at any process step.
"""
mutable struct Struct5216
    UseType::Union{Nothing,String}
    TimingType::Union{Nothing,TimingType}
end

"""
    mutable struct TimingType

The timing object fully describes the timing of an addition with options for basis on time, gravity, or pH at any process step.

Fields:
   `time`: What time during a process step is added, eg a value of 2 days for a dry hop addition would be added 2 days into the fermentation step.
   `duration`: How long an ingredient addition remains, this was referred to as time in the BeerXML standard. E.G. A 40 minute hop boil additions means to boil for 40 minutes, and a 2 day duration for a dry hop means to remove it after 2 days.
   `continuous`: A continuous addition is spread out evenly and added during the entire process step, eg 60 minute IPA by dogfish head takes all ofthe hop additions and adds them throughout the entire boil.
   `specific_gravity`: Used to indicate when an addition is added based on a desired specific gravity. E.G. Add dry hop at when SG is 1.018.
   `pH`: Used to indicate when an addition is added based on a desired specific pH. eg Add brett when pH is 3.4.
   `step`: Used to indicate what step this ingredient timing addition is referencing. EG A value of 2 for add_to_fermentation would mean to add during the second fermentation step.
   `use`:
"""
mutable struct TimingType
    time::Union{Nothing,TimeType}
    duration::Union{Nothing,TimeType}
    continuous::Union{Nothing,Bool}
    specific_gravity::Union{Nothing,GravityType}
    pH::Union{Nothing,AcidityType}
    step::Union{Nothing,Int}
    use::Union{Nothing,UseType}
end

end # module TimingJSON