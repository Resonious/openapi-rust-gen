require "json"
require "yaml"
require "debug"
require "uri"

class OpenApiRustGenerator
  attr_reader :async_trait

  def initialize(schema, want_send: true)
    @schema = schema
    @paths_by_method = collect_paths_by_method
    @lazy_defs = {}
    @enum_components = {}
    @conversions = {}
    @async_trait = want_send ? "async_trait" : "async_trait(?Send)"
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
      if c =~ /\w/ && c != '_'
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

  def each_struct_field(definition, &block)
    while ref = definition[:"$ref"]
      definition = follow_ref(ref)
    end

    if all_of = definition[:allOf]
      all_of.each { |d| each_struct_field(d, &block) }
      return
    end

    return if definition[:oneOf]

    required = {}
    definition.fetch(:required, []).each { |field| required[field] = true }

    definition.fetch(:properties).each do |key, prop|
      yield key, prop, required[key.to_s]
    end
  end

  def puts_struct_fields(output, definition, type_name_prefix)
    each_struct_field(definition) do |key, prop, required|
      puts_struct_field(output, key, prop, required, type_name_prefix)
    end
  end

  def puts_struct_field(output, key, prop, required, type_name_prefix)
    type = type_of(prop, camelize("#{type_name_prefix} #{key}"))
    type = "Option<#{type}>" unless required

    snake_key = snakeize(key)
    key = key.to_s

    if desc = prop[:description]
      desc.each_line { |line| output.puts "    /// #{line.strip}" }
    end

    if snake_key != key
      output.puts "    #[serde(alias = #{key.inspect})]"
      output.puts "    #[serde(rename(serialize = #{key.inspect}))]"
    end

    output.puts "    pub #{snake_key}: #{type},"
  end

  def with_is_builtin(value, obj)
    obj.define_singleton_method(:is_builtin?) { value }
    obj
  end

  def type_of(prop, type_name_if_definition_needed)
    if ref = prop[:"$ref"]
      %r{#/components/schemas/(?<type_name>\w+)$} =~ ref
      if type_name.nil?
        while ref = prop[:"$ref"]
          prop = follow_ref(ref)
        end
      else
        return with_is_builtin(false, type_name)
      end
    end

    is_builtin = true

    if one_of = prop[:oneOf]
      @lazy_defs[type_name_if_definition_needed] ||= prop
      return with_is_builtin(is_builtin, type_name_if_definition_needed)
    end

    result = case prop.fetch(:type)
    when "string"
      if prop[:enum]
        @lazy_defs[type_name_if_definition_needed] ||= prop
        @enum_components[type_name_if_definition_needed] ||= prop
        type_name_if_definition_needed
      else
        "String"
      end
    when "integer"
      case prop.fetch(:format, "int64")
      when "int8" then "i8"
      when "uint8" then "u8"
      when "int16" then "i16"
      when "uint16" then "u16"
      when "int32" then "i32"
      when "uint32" then "u32"
      when "int64" then "i64"
      when "uint64" then "u64"
      else raise "? #{prop.to_s.inspect}"
      end
    when "number"
      "f64"
    when "boolean"
      "bool"
    when "array" then "Vec<#{type_of(prop.fetch(:items), "#{type_name_if_definition_needed}Item")}>"
    when "object"
      is_builtin = false
      @lazy_defs[type_name_if_definition_needed] ||= prop
      type_name_if_definition_needed
    else
      raise "unknown type #{prop.to_s.inspect}"
    end

    with_is_builtin(is_builtin, result)
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

      case [parameter.fetch(:in), parameter.fetch(:required) { false }]
      in ["path", _] then result << type_of(parameter.fetch(:schema), type_name) << ",\n"
      in ["query", false] then result << "Option<" << type_of(parameter.fetch(:schema), type_name) << ">,\n"
      in ["query", true] then result << type_of(parameter.fetch(:schema), type_name) << ",\n"
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

    #[#{async_trait}]
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
      use matchit::{Match, Router};
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

    if server = @schema.fetch(:servers, []).first
      uri = URI(server.fetch(:url))
      base_path = uri.path
    end

    # Matchit routers for each HTTP method.
    @paths_by_method.each do |method, paths|
      o.puts "static #{snakeize(method).upcase}_ROUTER: Lazy<Router<#{camelize(method)}Path>> = Lazy::new(|| {"
      o.puts "    let mut router = Router::new();"
      paths.each do |path|
        full_path = (base_path || "") + path.to_s
        o.puts "    router.insert(#{full_path.to_s.inspect}, #{camelize(method)}Path::#{camelize(path)}).unwrap();"
      end
      o.puts "    router"
      o.puts "});"
    end

    o.puts

    # Create structs for all components.
    @schema.fetch(:components).fetch(:schemas).each do |model, definition|
      if one_of = definition[:oneOf]
        type_key = nil
        item_key = nil

        shared_fields = Hash.new { |h, k| h[k] = 0 }

        # Turn each oneOf array entry into a usable Rust type name.
        entries = one_of.map do |one_of_entry|
          case one_of_entry
          in {
            type: "object",
            required: [type, item],
            properties: props
          }
            if type_key && type_key != type.to_sym
              raise "oneOf with mismatched type keys #{type_key} & #{type}"
            end
            type_key = type.to_sym
            if item_key && item_key != item.to_sym
              raise "oneOf with mismatched item keys #{item_key} & #{item}"
            end
            item_key = item.to_sym

            type_name = case props[type_key]
            in {
              type: "string",
              enum: [just_one_item]
            }
              just_one_item
            else
              raise "Expected enum with one entry for type key (inferred to be #{type_key})"
            end

            real_type_name = type_of(props[item_key], type_name)
            if real_type_name != type_name
              raise "oneOf entry had type tag #{type_name} but actual type was inferred to be #{real_type_name}. These should line up."
            end

            each_struct_field(props[item_key]) do |*args|
              shared_fields[args] += 1
            end

            real_type_name
          else
            raise "oneOf must follow the Serde 'Adjacently tagged' format https://serde.rs/enum-representations.html#adjacently-tagged"
          end
        end

        shared_fields = shared_fields.keys.select do |key|
          shared_fields[key] == entries.size
        end

        o.puts "#[derive(Clone, Serialize, Deserialize, Debug)]"
        o.puts %{#[serde(tag = "#{type_key}", content = "#{item_key}")]}
        o.puts "pub enum #{model} {"
        entries.each do |type_name|
          o.puts "    #{type_name}(#{type_name}),"
        end
        o.puts "}"

        # If each entry has some shared fields, make it easy to get and set them
        # without needing to manually match on each entry.
        if shared_fields.size > 0
          o.puts "impl #{model} {"
          shared_fields.each do |key, value, required|
            snake_key = snakeize(key)
            return_type = type_of(value, camelize("#{model} #{key} probably a bug"))
            return_type = "Option<#{return_type}>" unless required
            o.puts "    pub fn #{snake_key}(&self) -> &#{return_type} {"
            o.puts "        match self {"
            entries.each do |entry_type|
              o.puts "            Self::#{entry_type}(x) => &x.#{snake_key},"
            end
            o.puts "        }"
            o.puts "    }"

            o.puts "    pub fn set_#{snake_key}(&mut self, value: #{return_type}) {"
            o.puts "        match self {"
            entries.each do |entry_type|
              o.puts "            Self::#{entry_type}(x) => x.#{snake_key} = value,"
            end
            o.puts "        }"
            o.puts "    }"

            o.puts "    pub fn with_#{snake_key}(mut self, value: #{return_type}) -> Self {"
            o.puts "        match &mut self {"
            entries.each do |entry_type|
              o.puts "            Self::#{entry_type}(x) => x.#{snake_key} = value,"
            end
            o.puts "        };"
            o.puts "        self"
            o.puts "    }"
          end
          o.puts "}"
        end

        entries.each do |type_name|
          next if type_name.is_builtin?

          o.puts "impl From<#{type_name}> for #{model} {"
          o.puts "    fn from(value: #{type_name}) -> #{model} {"
          o.puts "        #{model}::#{type_name}(value)"
          o.puts "    }"
          o.puts "}"
        end

        next
      end

      case definition.fetch(:type) { definition.fetch(:allOf) }
      when "object", Array
        o.puts "#[derive(Clone, Serialize, Deserialize, Debug)]"
        o.puts "pub struct #{model} {"
        puts_struct_fields(o, definition, model)

        if all_of = definition[:allOf]
          all_of.each do |d|
            if ref = d[:"$ref"]
              %r{#/components/schemas/(?<ref_type_name>\w+)$} =~ ref
              if ref_type_name
                while ref = d[:"$ref"]
                  d = follow_ref(ref)
                end
                @conversions[model] ||= []
                @conversions[model] << [ref_type_name, d]
              end
            end
          end
        end

        o.puts "}"
      when "array"
        items = definition.fetch(:items)
        o.puts "type #{model} = Vec<#{type_of(items, "#{model}Item")}>;"
      when "string"
        if definition[:enum]
          @lazy_defs[model] ||= definition
          @enum_components[model] ||= definition
        else
          o.puts "type #{model} = String;"
        end
      when "integer"
        t = case definition.fetch(:format, "int64")
            when "int16" then "i16"
            when "int32" then "i32"
            when "int64" then "i64"
            when "uint64" then "u64"
            else raise "? #{definition.to_s.inspect}"
            end
        o.puts "type #{model} = #{t};"
      # TODO here
      else
        raise "Unknown component type #{definition.inspect}"
      end
    end

    o.puts

    # pub enum GetAbcResponse { Http200(...), ... }
    # impl From<X> for GetAbcResponse { ... }
    @schema.fetch(:paths).each do |path, methods|
      methods.each do |method, definition|
        op_name = camelize(operation_name(method, path, definition))

        response_type = "#{op_name}Response"

        unique_enum_arg_types = {}
        non_unique_enum_arg_types = {}

        o.puts "#[derive(Debug)]"
        o.puts "pub enum #{response_type} {"
        definition.fetch(:responses).each do |status_code, response|
          while ref = response[:"$ref"]
            response = follow_ref(ref)
          end

          content = response.dig(:content, :"application/json", :schema)
          type = type_of(content, "#{response_type}#{response_enum_name(status_code, response)}") if content

          # Keep track of unique enum arg types.
          # If there is only one status code that responds with a certain type, we can
          # do an impl From<ThatType> for OpResponse.
          if type
            enum_args = "(#{type})"
            if unique_enum_arg_types[type]
              non_unique_enum_arg_types[type] = true
              unique_enum_arg_types.delete(type)
            elsif !non_unique_enum_arg_types[type]
              unique_enum_arg_types[type] = [type, status_code, response]
            end
          end

          if desc = response[:description]
            desc.each_line { |line| o.puts "    /// #{line.strip}" }
          end
          o.puts "    #{response_enum_name(status_code, response)}#{enum_args},"
        end
        o.puts "}"

        o.puts "impl #{response_type} {"
        o.puts "    pub fn status_code(&self) -> http::StatusCode {"
        o.puts "        match self {"
        definition.fetch(:responses).each do |status_code, response|
          while ref = response[:"$ref"]
            response = follow_ref(ref)
          end
          content = response.dig(:content, :"application/json", :schema)
          enum_args = "(_)" if content
          o.puts "            #{response_type}::#{response_enum_name(status_code, response)}#{enum_args} => StatusCode::from_u16(#{status_code.to_s.to_i}).unwrap(),"
        end
        o.puts "        }"
        o.puts "    }"
        o.puts "}"

        unique_enum_arg_types.each_value do |value|
          type, status_code, response = value
          content = response.dig(:content, :"application/json", :schema)

          o.puts "impl From<#{type}> for #{response_type} {"
          o.puts "    fn from(value: #{type}) -> #{response_type} {"
          o.puts "        #{response_type}::#{response_enum_name(status_code, response)}(value)"
          o.puts "    }"
          o.puts "}"

          unless type.is_builtin?
            o.puts "impl Into<Result<#{response_type}, #{response_type}>> for #{type} {"
            o.puts "    fn into(self) -> Result<#{response_type}, #{response_type}> {"
            o.puts "        Ok(#{response_type}::#{response_enum_name(status_code, response)}(self))"
            o.puts "    }"
            o.puts "}"
          end
        end
      end
    end

    o.puts

    # Api trait that users of the generated library must implement.
    # We can generate duplicate trait defs, one for wasm and one native, but then
    # what happens is consumer code also needs a dupe definition in order for
    # rust-anayzer to not freak out without exra config.
    o.puts "#[#{async_trait}]"
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
            Err(_) => {
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
              raise "cant handle #{type.inspect} path param"
            end

          in { in: "query", style: "form", name: }
            "query_pairs.get(#{name.inspect}).map(|x| x.into_iter().map(|el| el.to_string()).collect()),"

          in { in: "query", name: }
            getter = case type
            when "String"
              "query_pairs.get(#{name.inspect}).and_then(|x| x.first()).map(|x| x.to_string())"
            when /i\d{2}/
              "match query_pairs.get(#{name.inspect}).and_then(|x| x.first()).map(|x| x.parse()) { Some(Ok(x)) => Some(x), None => None, _ => return invalid_parameter(\"#{name} must be an integer\") }"
            else
              if @enum_components[type.to_sym]
                "match query_pairs.get(#{name.inspect}).and_then(|x| x.first()).map(|x| x.try_into()) { Some(Ok(x)) => Some(x), None => None, _ => return invalid_parameter(\"invalid #{name}\") }"
              else
                raise "cant handle #{type.inspect} query param"
              end
            end

            if parameter.fetch(:required) { false }
              "match #{getter} { Some(x) => x, None => return invalid_parameter(\"#{name} is required\") },"
            else
              "#{getter},"
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
          while ref = response[:"$ref"]
            response = follow_ref(ref)
            refd = true
          end
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
      o.puts "                Err(_) => {"
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

        if definition[:oneOf].is_a?(Array)
          if definition[:oneOf].length != 2
            raise "Sorry! Unsupported oneOf in inline struct (#{definition})"
          end

          null_types = definition[:oneOf].select { |d| d[:type] == "null" }
          if null_types.length != 1 || definition[:oneOf].length != 2
            raise "oneOf arrays with null types must be length 2 with exactly one null type (#{definition})"
          end

          non_null_type = (definition[:oneOf] - null_types).first
          type = type_of(non_null_type, "#{type_name}WhenPresent")
          o.puts "type #{type_name} = Option<#{type}>;"

        elsif definition[:type] == "object"
          o.puts "#[derive(Clone, Serialize, Deserialize, Debug)]"
          o.puts "pub struct #{type_name} {"
          puts_struct_fields(o, definition, type_name)
          o.puts "}"
        elsif (enum = definition[:enum])
          enum_key = enum.sort.inspect
          similar_enums[enum_key] ||= []
          similar_enums[enum_key] << [type_name, definition]
          default = definition[:default]

          derives = %w[Clone Serialize Deserialize Debug PartialEq Eq Hash]
          derives << "Default" if default

          o.puts "#[derive(#{derives.join(', ')})]"
          o.puts "pub enum #{type_name} {"
          enum.each do |item|
            camel = camelize(item)
            o.puts "    #[serde(rename = #{item.to_s.inspect})]" if camel != item
            o.puts "    #[default]" if item == default
            o.puts "    #{camel},"
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

          o.puts "impl ToString for #{type_name} {"
          o.puts "    fn to_string(&self) -> String {"
          o.puts "        self.as_str().to_string()"
          o.puts "    }"
          o.puts "}"

          ["&str", "&Cow<'_, str>"].each do |str_type|
            if default
              o.puts "impl From<#{str_type}> for #{type_name} {"
              o.puts "    fn from(value: #{str_type}) -> Self {"
              enum.each do |item|
                o.puts "        if value == #{item.inspect} { return Self::#{camelize(item)}; }"
              end
              o.puts "        Default::default()"
              o.puts "    }"
              o.puts "}"
            else
              o.puts "impl TryFrom<#{str_type}> for #{type_name} {"
              o.puts "    type Error = ();"
              o.puts "    fn try_from(value: #{str_type}) -> Result<Self, ()> {"
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
    end

    @conversions.each do |from_type, destinations|
      destinations.each do |dest|
        to_type, to_def = dest
        o.puts "impl From<#{from_type}> for #{to_type} {"
        o.puts "    fn from(value: #{from_type}) -> Self {"
        o.puts "        Self {"
        each_struct_field(to_def) do |key, _value, required|
          if required
            o.puts "            #{snakeize(key)}: value.#{snakeize(key)}.into(),"
          else
            o.puts "            #{snakeize(key)}: value.#{snakeize(key)}.map(|x| x.into()).into(),"
          end
        end
        o.puts "        }"
        o.puts "    }"
        o.puts "}"
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
    def test_camelize
      assert_equal "GetOneTwoThree", OpenApiRustGenerator.camelize("get", "/one/{two}/three")
      assert_equal "OneTwo", OpenApiRustGenerator.camelize("one_two")
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

  generator = OpenApiRustGenerator.new(schema, want_send: ARGV[2] != 'nosend')
  generator.generate_project(dir)

  puts
  puts "/* Done */"
end
