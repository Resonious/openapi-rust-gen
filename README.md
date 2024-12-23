# openapi-rust-gen

Generate very concise, low-dependency Rust server code from OpenAPI specifications.

Not as thorough as https://openapi-generator.tech/ but works very well for simple
specifications.

## Advantages

* Resulting code is server-agnostic, works directly with [the http crate](https://docs.rs/http/latest/http/)
    * This means it works with Cloudflare Workers or other wasm-based server runtimes
* Generator only depends on Ruby
* Generator runs quickly
* Generated struct and enum names should be sensible

## Disadvantages

* Not as thorough, might be missing OpenAPI features that I don't actively use
* Not currently very good with large nested inline objects
    * You'll get good results if you make use of #!/components/schemas, as each of these are converted to structs etc of the same name as the component

