using JSON3

json_string = read("jsonschema_examples/beerjson-1.0.1/json/beer.json", String)
json_schema = JSON3.read(json_string)

@show keys(json_schema)
for key in (Symbol("\$schema"), Symbol("\$id"))
    if key in keys(json_schema)
        println("$key: $(json_schema[key])")
    end
end