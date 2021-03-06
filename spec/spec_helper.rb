# This file is copied to spec/ when you run 'rails generate rspec:install'
ENV["RAILS_ENV"] ||= 'test'

require "rails/mongoid"
require File.expand_path("../dummy/config/environment", __FILE__)
require 'rspec/rails'
require 'rspec/autorun'
require 'mongoid-rspec'
require 'timecop'

# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories.

Dir[Rails.root.join("../../spec/support/**/*.rb")].each { |f| require f }

require 'miniskirt'
Dir[Rails.root.join("../../spec/factories/**/*_factory.rb")].each {|f| require f}

RSpec.configure do |config|
  config.include Mongoid::Matchers
  
  config.before(:each) do
    Timecop.return
    Mongoid.purge!
  end
  
  config.treat_symbols_as_metadata_keys_with_true_values = true
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true
  config.infer_base_class_for_anonymous_controllers = false
  config.order = "random"
end
