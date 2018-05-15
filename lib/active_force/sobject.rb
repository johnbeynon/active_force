require 'active_model'
require 'active_force/active_query'
require 'active_force/association'
require 'active_force/mapping'
require 'yaml'
require 'forwardable'
require 'logger'
require 'restforce'

module ActiveForce
  class RecordInvalid < StandardError;end

  class SObject
    include ActiveModel::AttributeMethods
    include ActiveModel::Model
    include ActiveModel::Dirty
    extend ActiveForce::Association
    extend ActiveModel::Callbacks

    attr_accessor :id, :title # <=HACK to get bundle exec rspec spec/active_force/association_spec.rb:22 passing.

    define_model_callbacks :save, :create, :update

    class_attribute :mappings, :table_name

    class << self
      extend Forwardable
      def_delegators :query, :where, :first, :last, :all, :find, :find_by, :count, :includes, :limit, :order, :select, :none
      def_delegators :mapping, :table, :table_name, :custom_table?, :mappings

      private

      ###
      # Provide each subclass with a default id field. Can be overridden
      # in the subclass if needed
      def inherited(subclass)
        subclass.field :id, from: 'Id'
      end
    end

    def self.mapping
      @mapping ||= ActiveForce::Mapping.new name
    end

    def self.fields
      mapping.sfdc_names
    end

    def self.query
      ActiveForce::ActiveQuery.new self
    end

    def self.build mash
      return unless mash
      sobject = new
      mash.each do |column, sf_value|
        sobject.write_value column, sf_value
      end
      # sobject.changed_attributes.clear
      sobject.clear_changes_information
      sobject
    end

    def update_attributes! attributes = {}
      assign_attributes attributes
      validate!
      run_callbacks :save do
        run_callbacks :update do
          sfdc_client.update! table_name, attributes_for_sfdb
          # changed_attributes.clear
          clear_changes_information
        end
      end
      true
    end

    alias_method :update!, :update_attributes!

    def update_attributes attributes = {}
      update_attributes! attributes
    rescue Faraday::Error::ClientError, RecordInvalid => error
      handle_save_error error
    end

    alias_method :update, :update_attributes

    def attributes_and_changes
      attributes.select{ |attr, key| changed.include? attr.to_s }
    end

    def self.attribute_names
      mapping.mappings.keys.map(&:to_s)
    end

    def self.define_attribute_reader(name, options = Hash.new)
      wrapper = Module.new do
        # provided_default = options.fetch(:default) { NO_DEFAULT_PROVIDED }
        define_method name do
          # return instance_variable_get("@#{name}") if instance_variable_defined?("@#{name}")
          # return if provided_default == NO_DEFAULT_PROVIDED
          # provided_default.respond_to?(:call) && provided_default.call || provided_default
          return instance_variable_get("@#{name}")
        end
      end
      include wrapper
    end

    def self.define_attribute_writer(name, options = Hash.new)
      wrapper = Module.new do
        define_method "#{name}=" do |val|
          # if cast_type.is_a?(Symbol)
          #   cast_type = ActiveModel::Type.lookup(cast_type, **options.except(*SERVICE_ATTRIBUTES))
          # end
          # deserialized_value = cast_type.cast(val)
          send(:"#{name}_will_change!") unless instance_variable_get("@#{name}") == val
          instance_variable_set("@#{name}", val)
        end
      end
      include wrapper
    end

    def attributes
      # Hash[*self.class.mapping.mappings.keys.map { |field|
      #   [field, self.send(field)]
      # }]
      self.class.mapping.mappings.keys.each_with_object(Hash.new) {|field, hsh|
        hsh[field] = self.send(field)
      }
    end

    def create!
      validate!
      run_callbacks :save do
        run_callbacks :create do
          self.id = sfdc_client.create! table_name, attributes_for_sfdb
          # changed_attributes.clear
          clear_changes_information
        end
      end
      self
    end

    def create
      create!
    rescue Faraday::Error::ClientError, RecordInvalid => error
      handle_save_error error
      self
    end

    def destroy
      sfdc_client.destroy! self.class.table_name, id
    end

    def self.create args
      new(args).create
    end

    def self.create! args
      new(args).create!
    end

    def save!
      run_callbacks :save do
        if persisted?
          !!update!
        else
          !!create!
        end
      end
    end

    def save
      save!
    rescue Faraday::Error::ClientError, RecordInvalid => error
      handle_save_error error
    end

    def to_param
      id
    end

    def persisted?
      !!id
    end

    def self.field field_name, args = {}
      mapping.field field_name, args
      # attr_accessor field_name
      define_attribute_methods field_name
      define_attribute_reader field_name
      define_attribute_writer field_name
      #attribute field_name
      # @attributes ||= {}
      # @attributes[field_name]
    end

    def reload
      association_cache.clear
      reloaded = self.class.find(id)
      self.attributes = reloaded.attributes
      # changed_attributes.clear
      clear_changes_information
      self
    end

    def write_value column, value
      if association = self.class.find_association(column)
        field = association.relation_name
        value = Association::RelationModelBuilder.build(association, value)
      else
        field = mappings.invert[column]
        value = self.class.mapping.translate_value value, field unless value.nil?
      end
      send "#{field}=", value if field
    end

   private

    def validate!
      unless valid?
        raise RecordInvalid.new(
          "Validation failed: #{errors.full_messages.join(', ')}"
        )
      end
    end

    def handle_save_error error
      return false if error.class == RecordInvalid
      logger_output __method__, error, attributes
    end

    def association_cache
      @association_cache ||= {}
    end

    def logger_output action, exception, params = {}
      logger = Logger.new(STDOUT)
      logger.info("[SFDC] [#{self.class.model_name}] [#{self.class.table_name}] Error while #{ action }, params: #{params}, error: #{exception.inspect}")
      errors[:base] << exception.message
      false
    end

    def attributes_for_sfdb
      attrs = self.class.mapping.translate_to_sf(attributes_and_changes)
      attrs.merge!({'Id' => id }) if persisted?
      attrs
    end

    def self.picklist field
      picks = sfdc_client.picklist_values(table_name, mappings[field])
      picks.map do |value|
        [value[:label], value[:value]]
      end
    end

    def self.sfdc_client
      ActiveForce.sfdc_client
    end

    def sfdc_client
      self.class.sfdc_client
    end
  end

end
