module AcmeNested

mutable struct Product
    productId::Int
    productName::String
    price::Number
    tags::Array{String}
    dimensions::Dimensions
end

mutable struct Dimensions
    length::Number
    width::Number
    height::Number
end

end # end module