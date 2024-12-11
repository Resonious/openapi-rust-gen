require "json"
require "debug"

def upper?(c) = c.upcase == c
def lower?(c) = c.downcase == c

def snakeize(*args)
  result_chars = []
  state = :start
  last_case = :upper

  args.join.chars.each_with_index do |c, index|
    if c =~ /\w/
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

def camelize(*args)
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

def generate_lib_rs(schema, o = STDOUT)
  o.puts <<~RUST
    use async_trait::*;
    use bytes::Bytes;
    use http::{HeaderName, Method, Request, Response, StatusCode};
    use http_body::Body as HttpBody;
    use http_body_util::BodyExt;
    use matchit::{Router, Match, MatchError};
    use once_cell::sync::Lazy;
    use std::{borrow::Cow, collections::HashMap};
    use url::Url;
  RUST
  o.puts

  # { method => Array<path> }
  paths_by_method = {}
  schema.fetch(:paths).each do |path, methods|
    methods.each do |method, definition|
      paths_by_method[method] ||= []
      paths_by_method[method] << path
    end
  end

  # enum GetPath {
  #   MyThings,
  #   YourThings,
  #   ...
  # }
  paths_by_method.each do |method, paths|
    o.puts "pub enum #{camelize(method)}Path {"
    paths.each do |path|
      o.puts "    #{camelize(path)},"
    end
    o.puts "}"
  end

  o.puts

  # statc GET_ROUTER = Lazy<Router<GetPath>> = Lazy::new(|| {
  #     let mut router = Router::new();
  #     router.insert("/my/things", GetPath::MyThings).unwrap();
  #     router.insert("/your/things", GetPath::YourThings).unwrap();
  #     ...
  #     router
  # });
  paths_by_method.each do |method, paths|
    o.puts "static #{snakeize(method).upcase}_ROUTER: Lazy<Router<#{camelize(method)}Path>> = Lazy::new(|| {"
    o.puts "    let mut router = Router::new();"
    paths.each do |path|
      o.puts "    router.insert(#{path.to_s.inspect}, #{camelize(method)}Path::#{camelize(path)}).unwrap();"
    end
    o.puts "    router"
    o.puts "});"
  end

  o.puts

  type_of = lambda do |prop|
    if ref = prop[:"$ref"]
      %r{#/components/schemas/(?<type_name>\w+)} =~ ref
      raise "??? #{ref}" if type_name.nil?
      next type_name
    end

    case prop.fetch(:type)
    when "string" then next "String"
    when "integer"
      case prop.fetch(:format)
      when "int32" then "i32"
      when "int64" then "i64"
      else raise "? #{prop.to_s.inspect}"
      end
    when "array" then "Vec<#{type_of[prop.fetch(:items)]}>"
    else
      raise "unknown type #{prop.to_s.inspect}"
    end
  end

  follow_ref = lambda do |ref|
    value = schema
    ref.split("/").each do |key|
      next if key == "#"
      value = value[key.to_sym]
    end
    value
  end

  puts_struct_fields = lambda do |definition|
    while ref = definition[:"$ref"]
      definition = follow_ref[ref]
    end

    required = {}
    definition.fetch(:required, []).each { |field| required[field] = true }

    definition.fetch(:properties).each do |key, prop|
      type = type_of[prop]
      type = "Option<#{type}>" unless required[key]
      o.puts "    #{key}: #{type},"
    end
  end

  schema.fetch(:components).fetch(:schemas).each do |model, definition|
    if all_of = definition[:allOf]
      o.puts "pub struct #{model} {"
      all_of.each(&puts_struct_fields)
      o.puts "}"
      next
    end

    case definition.fetch(:type)
    when "object"
      o.puts "pub struct #{model} {"
      puts_struct_fields[definition]
      o.puts "}"
    when "array"
      items = definition.fetch(:items)
      o.puts "type #{model} = Vec<#{type_of[items]}>;"
    end
  end

  o.puts

  operation_name = lambda do |method, path, definition|
    definition[:operationId] || "#{method} #{path}"
  end

  # request/response objects
  response_enum_name = lambda do |status_code, response|
    if status_code =~ /^\d/
      camelize("Http #{status_code}")
    else
      camelize(status_code)
    end
  end

  schema.fetch(:paths).each do |path, methods|
    methods.each do |method, definition|
      op_name = camelize(operation_name[method, path, definition])

      o.puts "pub enum #{op_name}Response {"
      definition.fetch(:responses).each do |status_code, response|
        content = response.dig(:content, :"application/json", :schema)
        type = type_of[content] if content
        enum_args = "(#{type})" if type

        o.puts "    #{response_enum_name[status_code, response]}#{enum_args},"
      end
      o.puts "}"
    end
  end

  o.puts

  # Api trait for user to implement

  o.puts "#[async_trait]"
  o.puts "pub trait Api {"
  functions = []
  schema.fetch(:paths).each do |path, methods|
    methods.each do |method, definition|
      op_name = operation_name[method, path, definition]
      camel_op_name = camelize(op_name)
      snake_op_name = snakeize(op_name)

      fn_def = [
        "    ",
        "async fn ",
        snake_op_name,
        "(\n",
        "        &mut self,\n"
      ]

      definition.fetch(:parameters, []).each do |parameter|
        fn_def << "        "
        fn_def << snakeize(parameter.fetch(:name)) << ": "

        case parameter.fetch(:in)
        when "path" then fn_def << type_of[parameter.fetch(:schema)] << ",\n"
        when "query" then fn_def << "Option<" << type_of[parameter.fetch(:schema)] << ">,\n"
        end
      end

      if (request_body = definition["requestBody"])
        content = request_body.dig(:content, :"application/json", :schema)
        fn_def << "        "
        fn_def << "body: " << type_of[content]
        fn_def << ",\n"
      end

      fn_def << "    ) -> " << camel_op_name << "Response;"

      functions << fn_def.join
    end
  end
  o.puts functions.join("\n\n")
  o.puts "}"

  o.puts

  # HTTP handler

  o.puts <<~RUST
  pub fn response<B: Into<Bytes>>(status: StatusCode, body: B) -> Response<Bytes> {
      Response::builder()
          .header(HeaderName::from_static("content-type"), "application/json")
          .status(status)
          .body(body.into())
          .unwrap()
  }

  pub fn invalid_parameter(message: &str) -> Response<Bytes> {
      let j = serde_json::json!({
          "error": "invalid_parameter",
          "message": message,
      });
      let body: Bytes = match serde_json::to_string(&j) {
          Ok(j_str) => j_str.into(),
          Err(_) => {
              "{\\"error\\":\\"invalid_parameter\\",\\"message\\":\\"failed to render full error mesage\\"}"
                  .into()
          }
      };

      response(StatusCode::UNPROCESSABLE_ENTITY, body)
  }

  pub async fn handle<A: Api, B: HttpBody>(
      api: &mut A,
      request: Request<B>,
  ) -> Response<Bytes> {
      let (parts, body) = request.into_parts();

      let Ok(url) = Url::parse(&parts.uri.to_string()) else {
          return response(StatusCode::BAD_REQUEST, "{\\"error\\":\\"bad URL\\"}");
      };
      let mut query_pairs = HashMap::new();
      for (key, value) in url.query_pairs() {
          query_pairs
              .entry(key)
              .and_modify(|e: &mut Vec<Cow<'_, str>>| e.push(value))
              .or_insert_with(|| vec![value]);
      }
  RUST
  o.puts
  o.puts "    match parts.method {"
  paths_by_method.each do |method, paths|
    o.puts "        Method::#{method.upcase} => {"
    o.puts "            match #{method.upcase}_ROUTER.at(parts.uri.path()) {"
    o.puts "                Ok(Match { value, params }) => {"
    o.puts "                    match value {"

    paths.each do |path|
      definition = schema.dig(:paths, path, method)
      raise "No def at #{method} #{path} ????" if definition.nil?
      op_name = operation_name[method, path, definition]
      camel_op_name = camelize(op_name)
      snake_op_name = snakeize(op_name)

      o.puts "                        #{camelize(method)}Path::#{camelize(path)} => {"

      args = definition.fetch(:parameters, []).map do |parameter|
        case parameter
        in { in: "path", name: }
          "params.get(#{name.inspect}).unwrap(),"

        in { in: "query", style: "form", name: }
          "query_pairs.get(#{name.inspect}).map(|x| x.into_iter().map(|el| el.to_string()).collect()),"

        in { in: "query", name: }
          "query_pairs.get(#{name.inspect}).and_then(|x| x.first()).map(|x| x.to_string()),"

        # TODO: need to handle non-string types....
        # probably in both the array case and not array case.

        else
          raise "Unknown parameter source #{parameter[:in].to_s.inspect}"
        end
      end

      o.puts "                            let result = api.#{snake_op_name}(\n"
      o.puts args.map { |a| "    " * 8 + a }.join("\n")
      o.puts "                            ).await;"
      o.puts "                            match result {"

      definition.fetch(:responses).each do |status_code, response|
        actual_status_code = status_code.to_s.to_i
        actual_status_code = 500 if actual_status_code < 100

        content = response.dig(:content, :"application/json", :schema)
        enum_args = "(body)" if content

        o.puts "                                #{camel_op_name}Response::#{response_enum_name[status_code, response]}#{enum_args} => {"
        o.puts "                                    let body = \"\";" unless enum_args
        o.puts "                                    response(StatusCode::from_u16(#{actual_status_code}).unwrap(), body)"
        o.puts "                                }"
      end

      o.puts "                            }"
      o.puts "                        }"
    end
    o.puts "                    }"
    o.puts "                }"
    o.puts "                Err(MatchError::NotFound) => {"
    o.puts "                    response(StatusCode::NOT_FOUND, \"{\\\"error\\\":\\\"path not found\\\"}\")"
    o.puts "                }"
    o.puts "            }"
    o.puts "        }"
  end
  o.puts "        _ => response(StatusCode::METHOD_NOT_ALLOWED, \"\\\"error\\\": \\\"method not allowed\\\"\")"
  o.puts "    }"
  o.puts "}"
end

def generate_cargo_toml(schema, name, o = STDOUT)
  title = schema.dig(:info, :title) || "api";

  o.puts <<~RUST
    [package]
    name = #{name.to_s.inspect}
    summary = #{title.to_s.inspect}
    version = "0.1.0"
    edition = "2021"

    [dependencies]
    async-trait = "0.1.83"
    bytes = "1.9.0"
    http = "1.1.0"
    http-body = "1.0.1"
    http-body-util = "0.1.2"
    matchit = "0.8.5"
    once_cell = "1.20.2"
    serde = { version = "1.0.215", features = ["derive"] }
    serde_json = "1.0.133"
    url = "2.5.4"
  RUST
end

def generate_project(schema, name)
  FileUtils.mkdir_p(name)
  Dir.chdir name do
    FileUtils.mkdir_p("src")

    File.open("Cargo.toml", "w") do |cargo_toml|
      generate_cargo_toml schema, name, cargo_toml
    end

    File.open("src/lib.rs", "w") do |lib_rs|
      generate_lib_rs schema, lib_rs
    end
  end
end

if ARGV[0] == 'test'
  require "minitest/autorun"

  class Test < Minitest::Test
    def setup
    end

    def test_path_enum_ident
      assert_equal "GetOneTwoThree", camelize("get", "/one/{two}/three")
      assert_equal "AlreadyCamelized", camelize("AlreadyCamelized")
    end

    def test_snake
      assert_equal "one_two_three", snakeize("/one/two/three")
      assert_equal "go_getit", snakeize("go GETIT")
      assert_equal "go_getit", snakeize("goGetit")
    end
  end
else
  json = File.read ARGV[0]
  schema = JSON.parse(json, symbolize_names: true)

  dir = ARGV[1]
  raise "usage: #{__FILE__} /path/to/schema.json project_dir" if dir.nil?

  generate_project schema, dir
  puts "Done."
end
