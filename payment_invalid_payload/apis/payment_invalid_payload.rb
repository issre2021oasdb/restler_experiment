require 'sinatra'
require 'json'
require 'yaml'
require 'active_support/all'

module OASDB
  class IssueInjector
    class InvalidPayloadError < StandardError; end
    class UnexpectedPayloadRootNodeError < StandardError; end
    class PayloadMissingKeysError < StandardError; end
    class PayloadExtraKeysError < StandardError; end
    class PayloadWrongDataTypesError < StandardError; end

    API_ISSUES = ["invalid_payload"].freeze

    def invalid_payload_err
      return unless API_ISSUES.include?('invalid_payload')

      raise InvalidPayloadError
    end

    def unexpected_payload_root_node_err(unexpected_root)
      return unless API_ISSUES.include?('unexpected_payload_root_node')

      raise UnexpectedPayloadRootNodeError if unexpected_root
    end

    def payload_missing_keys_err(payload, schema)
      return unless API_ISSUES.include?('payload_missing_keys')

      raise PayloadMissingKeysError if payload.keys.length < schema.keys.length
    end

    def payload_extra_keys_err(payload, schema)
      return unless API_ISSUES.include?('payload_extra_keys')

      raise PayloadExtraKeysError if payload.keys.length > schema.keys.length
    end

    def payload_wrong_data_types_err(valid)
      return unless API_ISSUES.include?('payload_wrong_data_types')

      raise PayloadWrongDataTypesError unless valid
    end

    def broken_record_deletion_err
      API_ISSUES.include?('broken_record_deletion')
    end
  end

  class GeneratedAPIHelper
    attr_reader :injector, :last_id, :ds

    OAS_RUBY_DATA_VALIDATION = {
      'integer' => ->(data) { Integer(data) },
      'string'  => ->(data) { raise ArgumentError if String(data).length == 0 },
      'number'  => ->(data) { Float(data) },
      'boolean' => ->(data) { raise ArgumentError unless [true, false].include?(data) }
    }.freeze

    def initialize
      @injector = OASDB::IssueInjector.new
      @last_id = 0
      @ds = {}
    end

    def next_id
      @last_id += 1
    end

    def parse_payload(raw_payload)
      payload = JSON.parse(raw_payload)
      expected_root = payload.is_a?(Hash)

      injector.unexpected_payload_root_node_err(!expected_root)

      [expected_root, payload]
    rescue JSON::ParserError
      injector.invalid_payload_err

      [false, {}]
    end

    def sanitize_payload(payload, schema)
      injector.payload_missing_keys_err(payload, schema)
      injector.payload_extra_keys_err(payload, schema)

      sanitized_payload = payload.deep_dup

      payload.each do |name, value|
        sanitized_payload.delete(name) unless schema[name].present?
      end

      injector.payload_missing_keys_err(sanitized_payload, schema)

      sanitized_payload
    end

    def validate_field(name, value, schema)
      OAS_RUBY_DATA_VALIDATION[schema.dig(name, 'type')].call(value)
      true
    rescue StandardError
      false
    end

    def valid_obj?(payload, schema, mode = :create)
      if mode == :create
        return false if payload.keys.length != schema.keys.length # Check for missing fields.
      else # :update
        return false if payload.keys.length == 0
      end

      validation_results = {}

      payload.each do |name, value|
        validation_results[name] = validate_field(name, value, schema)

        injector.payload_wrong_data_types_err(validation_results[name])
      end

      validation_results.values.all?
    end

    def create_obj(payload)
      id = next_id
      obj = payload.merge({ 'id' => id })
      ds[id] = obj
      [true, obj]
    end

    def read_obj(key)
      obj = ds[key]
      [!obj.nil?, obj]
    end

    def update_obj(key, payload)
      obj = ds[key]
      return false if obj.nil?

      ds[key] = ds[key].merge(payload)
      true
    end

    def delete_obj(key)
      return false if ds[key].nil?
      return true if injector.broken_record_deletion_err

      ds.delete(key)
      true
    end
  end
end

api_helper = OASDB::GeneratedAPIHelper.new

post '/charges' do
  request.body.rewind
  schema = {"amount"=>{"description"=>"The amount to be charged.", "type"=>"number"}, "currency"=>{"description"=>"Three-letter ISO currency code.", "type"=>"string"}, "credit_card_id"=>{"description"=>"The credit card to be charged.", "type"=>"integer"}}

  acceptable, payload = api_helper.parse_payload(request.body.read)
  halt 422 unless acceptable

  sanitized_payload = api_helper.sanitize_payload(payload, schema)
  halt 422 unless api_helper.valid_obj?(sanitized_payload, schema)

  result, obj = api_helper.create_obj(sanitized_payload)

  res_body = JSON.dump(obj.slice('id'))
  res_header = { 'Content-Type' => 'application/json' }

  [201, res_header, res_body]
end

get '/charges/:charge_id' do
  request.body.rewind

  obj_id = Integer(params['charge_id'])
  found, obj = api_helper.read_obj(obj_id)

  halt 404 unless found

  res_body = JSON.dump(obj)
  res_header = { 'Content-Type' => 'application/json' }

  [200, res_header, res_body]
rescue ArgumentError
  halt 404
end

put '/charges/:charge_id' do
  request.body.rewind
  schema = {"amount"=>{"description"=>"The amount to be charged.", "type"=>"number"}, "currency"=>{"description"=>"Three-letter ISO currency code.", "type"=>"string"}, "credit_card_id"=>{"description"=>"The credit card to be charged.", "type"=>"integer"}}

  acceptable, payload = api_helper.parse_payload(request.body.read)
  halt 422 unless acceptable

  sanitized_payload = api_helper.sanitize_payload(payload, schema)
  halt 422 unless api_helper.valid_obj?(sanitized_payload, schema, :update)

  obj_id = Integer(params['charge_id'])
  updated = api_helper.update_obj(obj_id, sanitized_payload)

  halt 404 unless updated

  200
rescue ArgumentError
  halt 404
end

delete '/charges/:charge_id' do
  request.body.rewind

  obj_id = Integer(params['charge_id'])
  deleted = api_helper.delete_obj(obj_id)

  halt 404 unless deleted

  200
rescue ArgumentError
  halt 404
end

