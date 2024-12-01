require "json"

def snakeize(*args)
  result_chars = []
  state = :start

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
      when :word
        result_chars << c.downcase
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
    end

    def test_snake
      assert_equal "one_two_three", snakeize("/one/two/three")
      assert_equal "go_getit", snakeize("go GETIT")
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

  paths_by_method.each do |method, paths|
    puts "pub enum #{camelize(method)}Path {"
    paths.each do |path|
      puts "    #{camelize(path)},"
    end
    puts "}"
  end

  puts

  paths_by_method.each do |method, paths|
    puts "static #{snakeize(method).upcase}_ROUTER: Lazy<Router<#{camelize(method)}Path>> = Lazy::new(|| {"
    puts "    let mut router = Router::new();"
    paths.each do |path|
      puts "    router.insert(#{path.inspect}, #{camelize(method)}Path::#{camelize(path)});"
    end
    puts "    router"
    puts "}"
  end
end
