module CloudModel
  class Address
    require 'netaddr'

    include Mongoid::Document
    include Mongoid::Timestamps
    
    embedded_in :host, :polymorphic => true
  
    field :ip, type: String
    field :subnet, type: Integer
    field :gateway, type: String
    
    validates :ip, presence: true
    validates :subnet, presence: true
    
    validate :check_ip_format
   
    def self.initialize(options)
      if options.class == String
        self.from_string options
      else
        super
      end
    end
   
    def self.from_str(str)
      cidr = ::NetAddr::CIDR.create(str)
      self.new ip: cidr.ip(Short: true), subnet: cidr.bits
    end
   
    def to_s
      if ip and subnet
        "#{ip}/#{subnet}"
      else
        ""
      end
    end
   
    def cidr
      if subnet
        ::NetAddr::CIDR.create("#{ip}/#{subnet}")
      else
        ::NetAddr::CIDR.create(ip)
      end
    end
    
    def network
      cidr.network
    end
    
    def netmask
      cidr.wildcard_mask
    end
    
    def broadcast
      cidr.broadcast if ip_version == 4
    end
    
    def ip_version
      cidr.version
    end
    
    def range?
      cidr.ip == cidr.network
    end
    
    def list_ips
      if range?
        cidr.enumerate[1..-2]
      else
        [ip]
      end
    end
    
    private
    def check_ip_format
      begin
        ::NetAddr::CIDR.create("#{ip}/#{subnet}")
      rescue Exception => e
        self.errors.add(:subnet, :format, default: e.message)
        return false
      end
    end
  end
end