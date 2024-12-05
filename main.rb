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
  schema = JSON.parse(json)

  puts <<~RUST
    use std::collections::HashMap;
    use async_trait::*;
    use http::{Method, Request, Response, StatusCode};
    use http_body::Body as HttpBody;
    use http_body_util::BodyExt;
    use bytes::Bytes;
    use matchit::{Match, MatchError};
    use once_cell::sync::Lazy;
    use url::Url;
  RUST
  puts

  # { method => Array<path> }
  paths_by_method = {}
  schema.fetch("paths").each do |path, methods|
    methods.each do |method, definition|
      paths_by_method[method] ||= []
      paths_by_method[method] << path
    end
  end

  # puts enum GetPath {
  #   MyThings,
  #   YourThings,
  #   ...
  # }
  paths_by_method.each do |method, paths|
    puts "pub enum #{camelize(method)}Path {"
    paths.each do |path|
      puts "    #{camelize(path)},"
    end
    puts "}"
  end

  puts

  # statc GET_ROUTER = Lazy<Router<GetPath>> = Lazy::new(|| {
  #     let mut router = Router::new();
  #     router.insert("/my/things", GetPath::MyThings).unwrap();
  #     router.insert("/your/things", GetPath::YourThings).unwrap();
  #     ...
  #     router
  # });
  paths_by_method.each do |method, paths|
    puts "static #{snakeize(method).upcase}_ROUTER: Lazy<Router<#{camelize(method)}Path>> = Lazy::new(|| {"
    puts "    let mut router = Router::new();"
    paths.each do |path|
      puts "    router.insert(#{path.inspect}, #{camelize(method)}Path::#{camelize(path)}).unwrap();"
    end
    puts "    router"
    puts "});"
  end

  puts

  type_of = lambda do |prop|
    if ref = prop["$ref"]
      %r{#/components/schemas/(?<type_name>\w+)} =~ ref
      raise "??? #{ref}" if type_name.nil?
      next type_name
    end

    case prop.fetch("type")
    when "string" then next "String"
    when "integer"
      case prop.fetch("format")
      when "int32" then "i32"
      when "int64" then "i64"
      else raise "? #{prop.inspect}"
      end
    when "array" then "Vec<#{type_of[prop.fetch("items")]}>"
    else
      raise "unknown type #{prop.inspect}"
    end
  end

  follow_ref = lambda do |ref|
    value = schema
    ref.split("/").each do |key|
      next if key == "#"
      value = value[key]
    end
    value
  end

  puts_struct_fields = lambda do |definition|
    while ref = definition["$ref"]
      definition = follow_ref[ref]
    end

    required = {}
    definition.fetch("required", []).each { |field| required[field] = true }

    definition.fetch("properties").each do |key, prop|
      type = type_of[prop]
      type = "Option<#{type}>" unless required[key]
      puts "    #{key}: #{type},"
    end
  end

  schema.fetch("components").fetch("schemas").each do |model, definition|
    if all_of = definition["allOf"]
      puts "pub struct #{model} {"
      all_of.each(&puts_struct_fields)
      puts "}"
      next
    end

    case definition.fetch("type")
    when "object"
      puts "pub struct #{model} {"
      puts_struct_fields[definition]
      puts "}"
    when "array"
      items = definition.fetch("items")
      puts "type #{model} = Vec<#{type_of[items]}>;"
    end
  end

  puts

  operation_name = lambda do |method, path, definition|
    definition["operationId"] || "#{method} #{path}"
  end

  # request/response objects
  response_enum_name = lambda do |status_code, response|
    if status_code =~ /^\d/
      camelize("Http #{status_code}")
    else
      camelize(status_code)
    end
  end

  schema.fetch("paths").each do |path, methods|
    methods.each do |method, definition|
      op_name = camelize(operation_name[method, path, definition])

      puts "pub enum #{op_name}Response {"
      definition.fetch("responses").each do |status_code, response|
        content = response.dig("content", "application/json", "schema")
        type = type_of[content] if content
        enum_args = "(#{type})" if type

        puts "    #{response_enum_name[status_code, response]}#{enum_args},"
      end
      puts "}"
    end
  end

  puts

  puts "#[async_trait]"
  puts "pub trait Api {"
  functions = []
  schema.fetch("paths").each do |path, methods|
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

      definition.fetch("parameters", []).each do |parameter|
        fn_def << "        "
        fn_def << snakeize(parameter.fetch("name")) << ": "

        case parameter.fetch("in")
        when "path" then fn_def << type_of[parameter.fetch("schema")] << ",\n"
        when "query" then fn_def << "Option<" << type_of[parameter.fetch("schema")] << ">,\n"
        end
      end

      if (request_body = definition["requestBody"])
        content = request_body.dig("content", "application/json", "schema")
        fn_def << "        "
        fn_def << "body: " << type_of[content]
        fn_def << ",\n"
      end

      fn_def << "    ) -> " << camel_op_name << "Response;"

      functions << fn_def.join
    end
  end
  puts functions.join("\n\n")
  puts "}"

  puts

  # HTTP handler

  puts "pub async fn handle<A: Api, B: HttpBody>(api: &mut A, request: Request<B>) -> Response<Bytes> {"
  puts "    let (parts, body) = request.into_parts();"
  puts
  puts "    let Ok(url) = Url::parse(&parts.uri.to_string()) else {"
  puts "        return Response::builder()"
  puts "            .status(StatusCode::BAD_REQUEST)"
  puts "            .body(\"{\\\"error\\\":\\\"bad URL\\\"}\".into()).unwrap();"
  puts "    };"
  puts "    let mut query_pairs = HashMap::new();"
  puts "    for (key, value) in url.query_pairs() {"
  puts "        query_pairs.insert(key, value);"
  puts "    }"
  puts
  puts "    match parts.method {"
  paths_by_method.each do |method, paths|
    puts "        Method::#{method.upcase} => {"
    puts "            match #{method.upcase}_ROUTER.at(parts.uri.path()) => {"
    puts "                Ok(Match { value, params }) => {"
    puts "                    match value {"

    paths.each do |path|
      definition = schema.dig("paths", path, method)
      raise "No def at #{method} #{path} ????" if definition.nil?
      op_name = operation_name[method, path, definition]
      camel_op_name = camelize(op_name)
      snake_op_name = snakeize(op_name)

      puts "                        #{camelize(method)}Path::#{camelize(path)} => {"

      args = definition.fetch("parameters", []).map do |parameter|
        case parameter.fetch("in")
        when "path"
          "params.get(#{parameter.fetch("name").inspect}).unwrap(),"
        when "query"
          "query_pairs.get(#{parameter.fetch("name").inspect}).map(|x| x.to_string()),"
        else
          raise "Unknown parameter source #{parameter["in"].inspect}"
        end
      end

      puts "                            let result = api.#{snake_op_name}(\n"
      puts args.map { |a| "    " * 8 + a }.join("\n")
      puts "                            ).await;"
      puts "                            match result {"

      definition.fetch("responses").each do |status_code, response|
        actual_status_code = status_code.to_i
        actual_status_code = 500 if actual_status_code < 100

        puts "                                #{camel_op_name}Response::#{response_enum_name[status_code, response]} => {"
        puts "                                    return Response::builder()"
        puts "                                        .status(StatusCode::from_u16(#{actual_status_code}).unwrap())"
        puts "                                        .body(result.into()).unwrap();"
        puts "                                }"
      end

      puts "                            }"
      puts "                        }"
    end

    puts "                    }"
    puts "                    Err(MatchError::NotFound) => {"
    puts "                        return Response::builder()"
    puts "                            .status(StatusCode::NOT_FOUND)"
    puts "                            .body(\"{\\\"error\\\":\\\"path not found\\\"}\".into()).unwrap();"
    puts "                    }"
    puts "                }"
    puts "            }"
    puts "        }"
  end
  puts "    }"
  puts "    Response::Builder()"
  puts "        .status(StatusCode::METHOD_NOT_ALLOWED)"
  puts "        .body(\\\"error\\\": \\\"method not allowed\\\".into()).unwrap()"
  puts "}"
end
