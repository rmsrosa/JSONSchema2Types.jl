# Conformance

The validation done by the generated types is checked against the official
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite), for
the 2020-12 dialect. The test is end to end: for each of the suite's test cases, a module
is generated from its schema, and each test instance is read with
`fromdict(RootType, instance)`, which must succeed exactly when the instance is valid.

## Results

| Tests | Passed |
|---|---|
| Core keywords | 1143 of 1179 (97%) |
| Formats (`format` checked, as by default) | 843 of 903 (93%) |
| Optional tests (big numbers, ECMAScript regular expressions...) | 189 of 206 (92%) |
| **All** | **2175 of 2288 (95%)** |

These are the results for the version of the test suite used in the continuous
integration of the package, which fails if fewer tests pass, to catch regressions.

## Known differences

Most of the tests that do not pass come from a few deliberate choices, or from features
that are not supported:

* **A schema with `properties` (or `required`, `additionalProperties`...) but no `type`
  is translated into a struct**, so it only accepts objects. Strictly, JSON Schema accepts
  any non-object value for such a schema, since these keywords only apply to objects. But
  schemas almost always mean an object there, and a struct is what makes them useful in
  Julia. (About 15 tests.)
* **`$dynamicRef` and `$dynamicAnchor` are resolved statically**, like `$ref` and
  `$anchor`. This is right for most uses, but not for the extension of recursive schemas
  through the dynamic scope. (About 15 tests.)
* **`hostname` and `idn-hostname` do not check the IDNA2008 rules** for internationalized
  domain names (Punycode labels, contextual rules for some characters...), so some invalid
  names are accepted. (About 60 tests.)
* **Numbers are `Int64` and `Float64`**, so integers beyond about ±9.2×10¹⁸ are rejected,
  and very precise decimals lose precision (the optional `bignum` tests).
* **`$vocabulary`** (custom metaschemas that turn validation off) and references to
  schemas of earlier drafts, processed with the rules of those drafts, are not supported.

## Running the test suite

```shell
git clone --depth 1 https://github.com/json-schema-org/JSON-Schema-Test-Suite /path/to/suite
julia --project=. test/json-schema-test-suite/run.jl /path/to/suite report.md
```

`report.md` has the results by file, and the description of every test that does not pass.
