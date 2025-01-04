require "json"
require "yaml"
require "debug"

class OpenApiRustGenerator
  def initialize(schema)
    @schema = schema
    @paths_by_method = collect_paths_by_method
    @lazy_defs = {}
  end

  def self.upper?(c) = c.upcase == c
  def self.lower?(c) = c.downcase == c

  def self.snakeize(*args)
    result_chars = []
    state = :start
    last_case = :upper

    args.join.chars.each_with_index do |c, index|
      if c == '_'
        result_chars << '_'
      elsif c =~ /\w/
        case state
        when :start
          result_chars << c.downcase
          state = :word
        when :was_word_sep
          result_chars << '_'
          result_chars << c.downcase
          state = :word
          last_case = :upper
        when :word
          result_chars << '_' if upper?(c) && last_case == :lower
          result_chars << c.downcase
          last_case = :lower if lower?(c)
          last_case = :upper if upper?(c)
        end
      else
        case state
        when :start then next
        else
          state = :was_word_sep
        end
      end
    end

    result_chars.join
  end

  def self.camelize(*args)
    result_chars = []
    state = :was_word_sep

    args.join.chars.each_with_index do |c, index|
      if c =~ /\w/
        case state
        when :was_word_sep
          result_chars << c.upcase
          state = :word
        when :word
          result_chars << c
        end
      else
        state = :was_word_sep
      end
    end

    result_chars.join
  end

  def camelize(*args) = self.class.camelize(*args)
  def snakeize(*args) = self.class.snakeize(*args)

  def generate_project(name)
    FileUtils.mkdir_p(name)
    Dir.chdir name do
      FileUtils.mkdir_p("src")

      File.open("Cargo.toml", "w") do |cargo_toml|
        generate_cargo_toml(name, cargo_toml)
      end

      File.open("src/lib.rs", "w") do |lib_rs|
        generate_lib_rs(lib_rs)
      end

      generate_example("crate", STDOUT)
    end
  end

  private

  def collect_paths_by_method
    result = {}
    @schema.fetch(:paths).each do |path, methods|
      methods.each do |method, definition|
        result[method] ||= []
        result[method] << path
      end
    end
    result
  end

  def operation_name(method, path, definition)
    definition.fetch(:operationId, "#{method} #{path}")
  end

  def response_enum_name(status_code, response)
    if status_code =~ /^\d/
      camelize("Http #{status_code}")
    else
      camelize(status_code)
    end
  end

  def follow_ref(ref)
    value = @schema
    ref.split("/").each do |key|
      next if key == "#"
      value = value[key.to_sym]
    end
    value
  end

  def puts_struct_fields(output, definition, type_name_prefix)
    while ref = definition[:"$ref"]
      definition = follow_ref(ref)
    end

    required = {}
    definition.fetch(:required, []).each { |field| required[field] = true }

    definition.fetch(:properties).each do |key, prop|
      type = type_of(prop, camelize("#{type_name_prefix} #{key}"))
      type = "Option<#{type}>" unless required[key.to_s]
      output.puts "    pub #{key}: #{type},"
    end
  end

  def type_of(prop, type_name_if_definition_needed)
    if ref = prop[:"$ref"]
      %r{#/components/schemas/(?<type_name>\w+)} =~ ref
      raise "??? #{ref}" if type_name.nil?
      return type_name
    end

    case prop.fetch(:type)
    when "string"
      if enum = prop[:enum]
        @lazy_defs[type_name_if_definition_needed] ||= prop
        type_name_if_definition_needed
      else
        "String"
      end
    when "integer"
      case prop.fetch(:format, "int64")
      when "int16" then "i16"
      when "int32" then "i32"
      when "int64" then "i64"
      else raise "? #{prop.to_s.inspect}"
      end
    when "number"
      "f64"
    when "boolean"
      "bool"
    when "array" then "Vec<#{type_of(prop.fetch(:items), "#{type_name_if_definition_needed}Item")}>"
    when "object"
      @lazy_defs[type_name_if_definition_needed] ||= prop
      type_name_if_definition_needed
    else
      raise "unknown type #{prop.to_s.inspect}"
    end
  end

  def fn_def(method, path, definition)
    op_name = operation_name(method, path, definition)
    camel_op_name = camelize(op_name)
    snake_op_name = snakeize(op_name)

    result = [
      "    ",
      "async fn ",
      snake_op_name,
    ]
    type_param_index = result.size
    result += [
      "(\n",
      "        self,\n"
    ]

    definition.fetch(:parameters, []).each do |parameter|
      result << "        "
      result << snakeize(parameter.fetch(:name)) << ": "

      type_name = camelize("#{op_name} #{parameter.fetch(:name)}")

      case parameter.fetch(:in)
      when "path" then result << type_of(parameter.fetch(:schema), type_name) << ",\n"
      when "query" then result << "Option<" << type_of(parameter.fetch(:schema), type_name) << ">,\n"
      end
    end

    if (request_body = definition[:requestBody])
      if (json_content = request_body.dig(:content, :"application/json", :schema))
        type_name = camelize("#{op_name} body")
        result << "        "
        result << "body: " << type_of(json_content, type_name)
        result << ",\n"
      else
        type_param = true
        result.insert type_param_index, "<B>"
        result << "        body: B,\n"
      end
    end

    return_type = "#{camel_op_name}Response"
    return_type = "Result<#{return_type}, #{return_type}>"

    result << "    ) -> " << return_type
    if type_param
      result << "\n        where B: http_body::Body + Send,\n"
      result << "        B::Data: Send,\n"
      result << "        B::Error: Send,\n    "
    end
    result.join
  end

  def generate_example(name, o)
    o.puts <<~RUST
    struct MyApi;

    #[async_trait(?Send)]
    impl #{name}::Api for MyApi {
    RUST

    @schema.fetch(:paths).each do |path, methods|
      methods.each do |method, definition|
        o.puts fn_def(method, path, definition) + " {"

        status_code, response = definition.fetch(:responses).each.next
        content = response.dig(:content, :"application/json", :schema)

        camel_op_name = camelize(operation_name(method, path, definition))

        line = ["Ok(", camel_op_name, "Response::", response_enum_name(status_code, response)]
        line << "(todo!()))" if content

        o.puts "        #{line.join}"

        o.puts "    }"
      end
    end

    o.puts "}"
  end

  def generate_lib_rs(o)
    o.puts <<~RUST
      use async_trait::*;
      use bytes::Bytes;
      use http::{HeaderName, Method, Request, Response, StatusCode};
      use http_body_util::BodyExt;
      use matchit::{Match, MatchError, Router};
      use once_cell::sync::Lazy;
      use serde::{de::DeserializeOwned, Deserialize, Serialize};
      use std::{borrow::Cow, collections::HashMap};
      use url::Url;
    RUST
    o.puts

    # Matchit result enums for each HTTP method.
    @paths_by_method.each do |method, paths|
      o.puts "pub enum #{camelize(method)}Path {"
      paths.each do |path|
        o.puts "    #{camelize(path)},"
      end
      o.puts "}"
    end

    o.puts

    # Matchit routers for each HTTP method.
    @paths_by_method.each do |method, paths|
      o.puts "static #{snakeize(method).upcase}_ROUTER: Lazy<Router<#{camelize(method)}Path>> = Lazy::new(|| {"
      o.puts "    let mut router = Router::new();"
      paths.each do |path|
        o.puts "    router.insert(#{path.to_s.inspect}, #{camelize(method)}Path::#{camelize(path)}).unwrap();"
      end
      o.puts "    router"
      o.puts "});"
    end

    o.puts

    # Create structs for all components.
    @schema.fetch(:components).fetch(:schemas).each do |model, definition|
      if all_of = definition[:allOf]
        o.puts "#[derive(Clone, Serialize, Deserialize, Debug)]"
        o.puts "pub struct #{model} {"
        all_of.each { |d| puts_struct_fields(o, d, model) }
        o.puts "}"
        next
      end

      case definition.fetch(:type)
      when "object"
        o.puts "#[derive(Clone, Serialize, Deserialize, Debug)]"
        o.puts "pub struct #{model} {"
        puts_struct_fields(o, definition, model)
        o.puts "}"
      when "array"
        items = definition.fetch(:items)
        o.puts "type #{model} = Vec<#{type_of(items, "#{model}Item")}>;"
      when "string"
        if definition[:enum]
          @lazy_defs[model] ||= definition
        else
          o.puts "type #{model} = String";
        end
      else
        raise "Unknown component type #{definition.inspect}"
      end
    end

    o.puts

    # pub enum GetAbcResponse { Http200(...), ... }
    @schema.fetch(:paths).each do |path, methods|
      methods.each do |method, definition|
        op_name = camelize(operation_name(method, path, definition))

        type_name = "#{op_name}Response"

        o.puts "pub enum #{type_name} {"
        definition.fetch(:responses).each do |status_code, response|
          content = response.dig(:content, :"application/json", :schema)
          type = type_of(content, "#{type_name}#{response_enum_name(status_code, response)}") if content
          enum_args = "(#{type})" if type

          o.puts "    #{response_enum_name(status_code, response)}#{enum_args},"
        end
        o.puts "}"
      end
    end

    o.puts

    # Api trait that users of the generated library must implement.
    # TODO: This (?Send) bit is necessary for wasm32 but breaks on native+tokio..
    # We can generate duplicate trait defs, one for wasm and one native, but then
    # what happens is consumer code also needs a dupe definition in order for
    # rust-anayzer to not freak out without exra config.
    o.puts "#[async_trait]"
    o.puts "pub trait Api {"
    functions = []
    @schema.fetch(:paths).each do |path, methods|
      methods.each do |method, definition|
        functions << fn_def(method, path, definition) + ';'
      end
    end
    o.puts functions.join("\n\n")
    o.puts "}"

    o.puts

    # Now we will generate all helper functions and the handler.
    o.puts <<~RUST
    pub fn response<B: Into<Bytes>>(status: StatusCode, body: B) -> Response<Bytes> {
        Response::builder()
            .header(HeaderName::from_static("content-type"), "application/json")
            .status(status)
            .body(body.into())
            .unwrap()
    }

    pub fn render_object<T: Serialize>(status: StatusCode, object: T) -> Response<Bytes> {
        let body: Bytes = match serde_json::to_string(&object) {
            Ok(json) => json.into(),
            Err(e) => {
                return render_error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "serialization_failure",
                    &format!("{e:?}"),
                )
            }
        };

        response(status, body)
    }

    pub fn render_error(status: StatusCode, error: &str, message: &str) -> Response<Bytes> {
        let j = serde_json::json!({
            "error": error,
            "message": message,
        });
        let body: Bytes = match serde_json::to_string(&j) {
            Ok(j_str) => j_str.into(),
            Err(_) => {
                format!("{{\\"error\\":\\"{error}\\",\\"message\\":\\"failed to render full error mesage\\"}}")
                    .into()
            }
        };

        response(status, body)
    }

    pub fn invalid_parameter(message: &str) -> Response<Bytes> {
        render_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_parameter",
            message,
        )
    }

    pub async fn read_object<B, T>(body: B) -> Result<T, Response<Bytes>>
        where B: http_body::Body + Send, T: DeserializeOwned
    {
        let body_bytes = match body.collect().await {
            Ok(result) => result.to_bytes(),
            Err(e) => {
                return Err(render_error(
                    StatusCode::BAD_REQUEST,
                    "read_failed",
                    "failed to read body",
                ));
            }
        };
        let Ok(string) = String::from_utf8(body_bytes.into()) else {
            return Err(render_error(
                StatusCode::BAD_REQUEST,
                "encoding_error",
                "invalid utf8 in body",
            ));
        };
        let arg = match serde_json::from_str(&string) {
            Ok(result) => result,
            Err(e) => {
                return Err(render_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_input",
                    &format!("body does not conform to schema: {}", e),
                ));
            }
        };

        Ok(arg)
    }

    pub async fn handle<A, B>(
        api: A,
        request: Request<B>,
    ) -> Response<Bytes>
        where A: Api,
              B: http_body::Body + Send,
              B::Data: Send,
              B::Error: Send,
    {
        let (parts, body) = request.into_parts();

        let uri = parts.uri.to_string();
        let uri = if uri.starts_with("/") {
            format!("http://host{uri}")
        } else {
            uri
        };
        let url = match Url::parse(&uri) {
            Ok(parsed) => parsed,
            Err(_) => return response(StatusCode::BAD_REQUEST, "{\\"error\\":\\"bad URL\\"}"),
        };
        let mut query_pairs = HashMap::new();
        for (key, value) in url.query_pairs() {
            let v1 = value.clone();
            let v2 = value.clone();
            query_pairs
                .entry(key)
                .and_modify(|e: &mut Vec<Cow<'_, str>>| e.push(v1))
                .or_insert_with(|| vec![v2]);
        }
    RUST
    o.puts
    o.puts "    match parts.method {"
    @paths_by_method.each do |method, paths|
      o.puts "        Method::#{method.upcase} => {"
      o.puts "            match #{method.upcase}_ROUTER.at(parts.uri.path()) {"
      o.puts "                Ok(Match { value, params }) => {"
      o.puts "                    match value {"

      paths.each do |path|
        definition = @schema.dig(:paths, path, method)
        raise "No def at #{method} #{path} ????" if definition.nil?
        op_name = operation_name(method, path, definition)
        camel_op_name = camelize(op_name)
        snake_op_name = snakeize(op_name)

        o.puts "                        #{camelize(method)}Path::#{camelize(path)} => {"

        args = definition.fetch(:parameters, []).map do |parameter|
          type_name = camelize("#{op_name} #{parameter.fetch(:name)}")
          type = type_of(parameter.fetch(:schema), type_name)

          case parameter
          in { in: "path", name: }
            case type
            when "String"
              "params.get(#{name.inspect}).unwrap().to_string(),"
            when /i\d{2}/
              "match params.get(#{name.inspect}).unwrap().parse() { Ok(x) => x, _ => return invalid_parameter(\"#{name} must be an integer\") },"
            else
              raise "cant hanle #{type.inspect} path param"
            end

          in { in: "query", style: "form", name: }
            "query_pairs.get(#{name.inspect}).map(|x| x.into_iter().map(|el| el.to_string()).collect()),"

          in { in: "query", name: }
            case type
            when "String"
              "query_pairs.get(#{name.inspect}).and_then(|x| x.first()).map(|x| x.to_string()),"
            when /i\d{2}/
              "match query_pairs.get(#{name.inspect}).and_then(|x| x.first()).map(|x| x.parse()) { Some(Ok(x)) => Some(x), None => None, _ => return invalid_parameter(\"#{name} must be an integer\") },"
            else
              raise "cant hanle #{type.inspect} query param"
            end
          else
            raise "Unknown parameter source #{parameter[:in].to_s.inspect}"
          end
        end

        if (request_body = definition[:requestBody])
          if (request_body.dig(:content, :"application/json", :schema))
            args << "match read_object(body).await { Ok(x) => x, Err(resp) => return resp }"
          else
            args << "body"
          end
        end

        o.puts "                            let result = match api.#{snake_op_name}(\n"
        o.puts args.map { |a| "    " * 8 + a }.join("\n")
        o.puts "                            ).await { Ok(x) => x, Err(x) => x };"
        o.puts "                            match result {"

        definition.fetch(:responses).each do |status_code, response|
          actual_status_code = status_code.to_s.to_i
          actual_status_code = 500 if actual_status_code < 100

          content = response.dig(:content, :"application/json", :schema)
          enum_args = "(body)" if content

          o.puts "                                #{camel_op_name}Response::#{response_enum_name(status_code, response)}#{enum_args} => {"
          o.puts "                                    let body = \"\";" unless enum_args
          o.puts "                                    render_object(StatusCode::from_u16(#{actual_status_code}).unwrap(), body)"
          o.puts "                                }"
        end

        o.puts "                            }"
        o.puts "                        }"
      end
      o.puts "                    }"
      o.puts "                }"
      o.puts "                Err(MatchError::NotFound) => {"
      o.puts "                    render_error(StatusCode::NOT_FOUND, \"not_found\", &format!(\"{} {} is not a valid endpoint\", parts.method.as_str(), url.path()))"
      o.puts "                }"
      o.puts "            }"
      o.puts "        }"
    end
    o.puts "        _ => response(StatusCode::METHOD_NOT_ALLOWED, \"{\\\"error\\\": \\\"method not allowed\\\"}\")"
    o.puts "    }"
    o.puts "}"

    similar_enums = {}

    # Lazy defs are inline structs and enums. Rust requires all
    # structs and enums to have a name, and so we pick these up
    # whenever type_of gets called on such an inline type.
    until @lazy_defs.empty?
      defs = @lazy_defs.dup
      @lazy_defs = {}
      defs.each do |type_name, definition|
        o.puts

        if definition[:type] == "object"
          o.puts "#[derive(Clone, Serialize, Deserialize, Debug)]"
          o.puts "pub struct #{type_name} {"
          puts_struct_fields(o, definition, type_name)
          o.puts "}"
        elsif (enum = definition[:enum])
          enum_key = enum.sort.inspect
          similar_enums[enum_key] ||= []
          similar_enums[enum_key] << [type_name, definition]
          default = definition[:default]

          derives = %w[Clone Serialize Deserialize Debug PartialEq Eq]
          derives << "Default" if default

          o.puts "#[derive(#{derives.join(', ')})]"
          o.puts "pub enum #{type_name} {"
          enum.each do |item|
            o.puts "    #[serde(rename = #{item.to_s.inspect})]"
            o.puts "    #[default]" if item == default
            o.puts "    #{camelize(item)},"
          end
          o.puts "}"

          o.puts "impl #{type_name} {"
          o.puts "    pub fn as_str(&self) -> &'static str {"
          o.puts "        match self {"
          enum.each do |item|
            o.puts "            Self::#{camelize(item)} => #{item.inspect},"
          end
          o.puts "        }"
          o.puts "    }"
          o.puts "}"

          if default
            o.puts "impl From<&str> for #{type_name} {"
            o.puts "    fn from(value: &str) -> Self {"
            enum.each do |item|
              o.puts "        if value == #{item.inspect} { return Self::#{camelize(item)}; }"
            end
            o.puts "        Default::default()"
            o.puts "    }"
            o.puts "}"
          else
            o.puts "impl TryFrom<&str> for #{type_name} {"
            o.puts "    type Error = ();"
            o.puts "    fn try_from(value: &str) -> Result<Self, ()> {"
            enum.each do |item|
              o.puts "        if value == #{item.inspect} { return Ok(Self::#{camelize(item)}); }"
            end
            o.puts "        Err(())"
            o.puts "    }"
            o.puts "}"
          end
        end
      end
    end

    # Generate "impl From"s for duplicate enums.
    # Duplicate enums happen when you have an inline enum field
    # in a ref that gets used with all_of.
    # It could also just be multiple enums with the same fields.
    similar_enums.each do |key, definitions|
      next if definitions.size <= 1
      definitions.permutation(2).each do |a, b|
        a_type, a_def = a
        b_type, b_def = b

        o.puts
        o.puts "impl From<#{a_type}> for #{b_type} {"
        o.puts "    fn from(value: #{a_type}) -> Self {"
        o.puts "        match value {"
        a_def.fetch(:enum).each do |item|
          item = camelize(item)
          o.puts "            #{a_type}::#{item} => Self::#{item},"
        end
        o.puts "        }"
        o.puts "    }"
        o.puts "}"
      end
    end
  end

  def generate_cargo_toml(name, output)
    title = @schema.dig(:info, :title) || "api"

    output.puts <<~RUST
      [package]
      name = #{name.to_s.inspect}
      summary = #{title.to_s.inspect}
      version = "0.1.0"
      edition = "2021"

      [dependencies]
      async-trait = "0.1.83"
      bytes = "1.9.0"
      http = "*"
      http-body = "*"
      http-body-util = "*"
      matchit = "*"
      once_cell = "*"
      serde = { version = "1.0.215", features = ["derive"] }
      serde_json = "1.0.133"
      url = "2.5.4"
    RUST
  end
end

if ARGV[0] == 'test'
  require "minitest/autorun"

  class Test < Minitest::Test
    def test_path_enum_ident
      assert_equal "GetOneTwoThree", OpenApiRustGenerator.camelize("get", "/one/{two}/three")
      assert_equal "AlreadyCamelized", OpenApiRustGenerator.camelize("AlreadyCamelized")
    end

    def test_snake
      assert_equal "one_two_three", OpenApiRustGenerator.snakeize("/one/two/three")
      assert_equal "go_getit", OpenApiRustGenerator.snakeize("go GETIT")
      assert_equal "go_getit", OpenApiRustGenerator.snakeize("goGetit")
      assert_equal "page_token", OpenApiRustGenerator.snakeize("page_token")
    end
  end
else
  if ARGV[0].end_with?(".yaml", ".yml")
    schema = YAML.load_file(ARGV[0], symbolize_names: true)
  elsif ARGV[0].end_with?(".json")
    json = File.read ARGV[0]
    schema = JSON.parse(json, symbolize_names: true)
  else
    raise "Unknown file type. Expected .json, .yaml, or .yml"
  end

  dir = ARGV[1]
  raise "usage: #{__FILE__} /path/to/schema.json project_dir" if dir.nil?

  generator = OpenApiRustGenerator.new(schema)
  generator.generate_project(dir)

  puts
  puts "/* Done */"
end
