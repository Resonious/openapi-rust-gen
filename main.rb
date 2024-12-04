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

  puts "use matchit::Router;"
  puts "use once_cell::sync::Lazy;"
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

  # TODO: maybe generate the trait here?
  operation_name = lambda do |method, path, definition|
    definition["operationId"] || "#{method} #{path}"
  end

  # request/response??
  schema.fetch("paths").each do |path, methods|
    methods.each do |method, definition|
      op_name = camelize(operation_name[method, path, definition])

      puts "pub enum #{op_name}Response {"
      definition.fetch("responses").each do |status_code, response|
        content = response.dig("content", "application/json", "schema")
        type = type_of[content] if content
        enum_args = "(#{type})" if type

        puts "    #{camelize("Http #{status_code}")}#{enum_args},"
      end
      puts "}"
    end
  end

  puts

  schema.fetch("paths").each do |path, methods|
    methods.each do |method, definition|
      puts snakeize(operation_name[method, path, definition])
    end
  end
end
