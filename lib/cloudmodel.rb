require "cloud_model/config"
require "cloud_model/engine"
require "cloud_model/call_rake"
require "cloud_model/enum_fields"
require "cloud_model/accept_size_strings"
require "cloud_model/used_in_guests_as"

module CloudModel  
  def self.config
    @config ||= CloudModel::Config.new
  end
  
  def self.configure(&block)
    config.configure(&block)
  end

end