module AcmeNested

"""
    mutable struct Product

A product from Acme's catalog

Fields:
   `productId`: The unique identifier for a product
   `productName`: Name of the product
   `price`: The price of the product
   `tags`: Tags for the product
   `dimensions`: Dimensions of a product
"""
mutable struct Product
    productId::Int
    productName::String
    price::Float64
    tags::Array{String}
    dimensions::Dimensions
end

"""
    mutable struct Dimensions

Dimensions of a product
"""
mutable struct Dimensions
    length::Float64
    width::Float64
    height::Float64
end

end # end module