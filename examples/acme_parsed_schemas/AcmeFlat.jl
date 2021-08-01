module AcmeFlat

mutable struct Product
    productId::Int
    productName::String
    price::Number
    tags::Array{String}
end

end # end module