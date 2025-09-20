module AcmeFlat

"""
    mutable struct Product

A product from Acme's catalog

Fields:
   `productId`: The unique identifier for a product
   `productName`: Name of the product
   `price`: The price of the product
   `tags`: Tags for the product
"""
mutable struct Product
    productId::Int
    productName::String
    price::Float64
    tags::Union{Nothing,Vector{String}}
end

end # module AcmeFlat