include("../src/json_schema_to_julia_gemini.jl")

# Creates dummy schema files for the demonstration
function create_example_schemas(dir::String)
    # No longer checking or creating the directory
    
    customer_schema_content = """
    {
      "\$id": "https://example.com/customer.schema.json",
      "\$defs": {
        "Customer": {
          "type": "object",
          "properties": {
            "id": { "type": "integer" },
            "name": { "type": "string" },
            "email": { "type": "string", "format": "email" }
          },
          "required": ["id", "name"]
        }
      }
    }
    """
    
    order_schema_content = """
    {
      "title": "Order",
      "type": "object",
      "properties": {
        "orderId": { "type": "string" },
        "customer": { "\$ref": "customer_schema.json#/\$defs/Customer" },
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "productId": { "type": "string" },
              "quantity": { "type": "integer" }
            },
            "required": ["productId", "quantity"]
          }
        }
      },
      "required": ["orderId", "customer", "items"]
    }
    """
    
    open(joinpath(dir, "customer_schema.json"), "w") do f
        write(f, customer_schema_content)
    end
    
    open(joinpath(dir, "order_schema.json"), "w") do f
        write(f, order_schema_content)
    end
    
    println("Created example schema files: customer_schema.json and order_schema.json")
end

create_example_schemas("examples/gemini_schemas/")

generate_julia_types("examples/gemini_schemas/order_schema.json", "examples/gemini_parsed_schemas/schema_types.jl")