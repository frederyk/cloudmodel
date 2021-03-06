require 'net/ssh'
require 'net/sftp'

module CloudModel
  class Host
    include Mongoid::Document
    include Mongoid::Timestamps
    include CloudModel::ENumFields
  
    field :name, type: String
    field :tinc_public_key, type: String
    field :initial_root_pw, type: String

    enum_field :stage, values: {
      0x00 => :pending,
      0x10 => :testing,
      0x30 => :staging,
      0x40 => :production,
    }, default: :pending
    
    enum_field :deploy_state, values: {
      0x00 => :pending,
      0x01 => :running,
      0x02 => :booting,
      0xf0 => :finished,
      0xf1 => :failed,
      0xff => :not_started
    }, default: :not_started
    
    field :deploy_last_issue, type: String
    
    has_many :guests, class_name: "CloudModel::Guest", inverse_of: :host
    embeds_many :addresses, class_name: "CloudModel::Address", inverse_of: :host do
      def << (value)
        if value.class == String
          value = CloudModel::Address.from_str(value)
        elsif value.class == Hash
          value = CloudModel::Address.new(value)
        end
        
        super value
      end
    end
    accepts_nested_attributes_for :addresses, allow_destroy: true
    
    embeds_one :primary_address, class_name: "CloudModel::Address", autobuild: true, inverse_of: :host
    accepts_nested_attributes_for :primary_address  
    
    embeds_one :private_network, class_name: "CloudModel::Address", autobuild: true, inverse_of: :host
    accepts_nested_attributes_for :private_network  
  
    has_many :volume_groups, class_name: "CloudModel::VolumeGroup", inverse_of: :host
    accepts_nested_attributes_for :volume_groups  
    
    validates :name, presence: true, uniqueness: true, format: {with: /\A[a-z0-9\-_]+\z/}
    validates :primary_address, presence: true
    validates :private_network, presence: true    
   
    def default_root_volume_group
      volume_groups.first
    end
    
    def default_data_volume_group
      volume_groups.last
    end
   
    def addresses=(value)
      self.addresses.clear
      value.each do |v|
        self.addresses << v
      end
    end
   
    def primary_address_with_strings=(value)
      if value.class == String
       value = CloudModel::Address.from_str(value)
      end

      self.primary_address_without_strings = value
    end
    alias_method_chain :primary_address=, :strings
    
    def private_network_with_strings=(value)
      if value.class == String
        value = CloudModel::Address.from_str(value)
      end
      
      self.private_network_without_strings = value
    end
    alias_method_chain :private_network=, :strings
  
    def available_private_address_collection
      all = private_network.list_ips - [private_network.gateway]
      used = guests.map{ |g| g.private_address }
      all - used
    end
    
    def available_external_address_collection
      all = addresses.map{ |a| a.list_ips if a.ip_version == 4 }.flatten
      used = guests.map{ |g| g.external_address }
      all - used - [nil]
    end
    
    def dhcp_private_address
      available_private_address_collection.last
    end
    
    def dhcp_external_address
      available_external_address_collection.last
    end
  
    def tinc_private_key
      require 'openssl'
      key = OpenSSL::PKey::RSA.new(2048)
    
      self.update_attributes tinc_public_key: key.public_key.to_s
    
      key
    end
    
    def to_param
      name
    end
    
    def ssh_connection
      @ssh_connection ||= if initial_root_pw
        Net::SSH.start(primary_address.ip, "root",
          password: initial_root_pw, 
          paranoid: false
        )
      else  
        Net::SSH.start(private_network.list_ips.first, "root",
          keys: ["#{CloudModel.config.data_directory}/keys/id_rsa"],
          keys_only: true,
          password: ''
        )        
      end
    end
    
    def sync_inst_images
      # TODO: make work with initial root pw
      ssh_address = initial_root_pw ? primary_address.ip : private_network.list_ips.first
      command = "rsync -avz -e 'ssh -i #{CloudModel.config.data_directory.shellescape}/keys/id_rsa' #{CloudModel.config.data_directory.shellescape}/inst/ root@#{ssh_address}:/inst"
      Rails.logger.debug command
      `#{command}`
    end
    
    def exec command
      Rails.logger.debug "EXEC: #{command}"
      
      stdout_data = ''
      stderr_data = {}
      exit_status = nil
      exit_signal = nil
      #puts command
      
      # Close SFTP channel as it would break the ssh loop
      ssh_connection.sftp.close_channel
      ssh_connection.instance_variable_set('@sftp', nil)
      
      ssh_connection.open_channel do |channel|
        channel.exec(command) do |ch, success|
          unless success
            abort "FAILED: couldn't execute command (ssh.channel.exec)"
          end
          channel.on_data do |ch,data|
            #puts "  stdout: #{data}"
            stdout_data += data
          end

          channel.on_extended_data do |ch,type,data|
            #puts "  stderr (#{type}): #{data}"
            stderr_data[type] ||= ''
            stderr_data[type] += data
          end

          channel.on_request("exit-status") do |ch,data|
            #puts "  exit-status: #{data}"
            exit_status = data.read_long
          end

          channel.on_request("exit-signal") do |ch, data|
            #puts "  exit-signal: #{data}"
            exit_signal = data.read_long
          end
        end
      end
      ssh_connection.loop
      
      success = exit_status == 0      
      Rails.logger.debug [success, stdout_data, stderr_data, exit_status, exit_signal]
      return [success, stdout_data]
    end

    def exec! command, message
      success, data = exec command

      unless success
        raise "#{message}: #{data}"
      end
      data
    end
    
    def boot_fs_mounted? root=''
      exec('mount')[1].match(/on #{root}\/boot type/)
    end
    
    def mount_boot_fs root=''
      # Don't mount /boot if already mounted!
      if boot_fs_mounted? root
        return true
      else
        success, data = exec "mount /dev/md127 #{root}/boot"
        unless success
          success, data = exec "mount /dev/md/rescue:127 #{root}/boot"
        end
        
        return success
      end
    end
    
    def list_real_volume_groups
      #begin
        success, result = exec "vgs --separator ';' --units b --all --nosuffix -o vg_all"
        volume_groups = {}
    
        lines = result.split("\n")
        head = lines.shift.split(";").map{|c| c.strip.sub('#', '').gsub(' ', '_').underscore.to_sym}

        lines.each do |row|
          columns = row.split(";")
          row_hash = {}
          head.each do |n|
            row_hash[n] = columns.shift.strip
          end
      
          name = row_hash.delete(:vg).to_sym
          volume_groups[name] = row_hash
        end

        return volume_groups
        #rescue
        #end
    end
    
    def deployable?
      [:finished, :failed, :not_started].include? deploy_state
    end
    
    def deploy(options = {})
      unless deployable? or options[:force]
        return false
      end
      
      update_attribute :deploy_state, :pending
      
      begin
        CloudModel::call_rake 'cloudmodel:host:deploy', host_id: id
      rescue
        update_attributes deploy_state: :failed, deploy_last_issue: 'Unable to enqueue job! Try again later.'
      end
    end
    
    def redeploy(options = {})
      unless deployable? or options[:force]
        return false
      end
      
      update_attribute :deploy_state, :pending
      
      begin
        CloudModel::call_rake 'cloudmodel:host:redeploy', host_id: id
      rescue
        update_attributes deploy_state: :failed, deploy_last_issue: 'Unable to enqueue job! Try again later.'
      end
    end
  end
end
