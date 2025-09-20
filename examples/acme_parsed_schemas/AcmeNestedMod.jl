module AcmeNestedMod

"""
    mutable struct Product

A product from Acme's catalog

Fields:
   `productId`: The unique identifier for a product
   `productName`: Name of the product
   `price`: The price of the product
   `tags`: Tags for the product
   `dimensions`:
"""
mutable struct Product
    productId::Int
    productName::String
    price::Float64
    tags::Union{Nothing,Vector{String}}
    dimensions::Union{Nothing,Dimensions}
end

mutable struct Dimensions
    length::Float64
    width::Float64
    height::Float64
end

end # module AcmeNestedMod