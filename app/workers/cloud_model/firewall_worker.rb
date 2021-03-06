module CloudModel
  class FirewallWorker < BaseWorker
    def initialize(host)
      @host = host
      
      rules = {
        @host.primary_address.ip  => {
          'interface' => 'eth0',
          'services' => {
            'ssh' => {
              'port' => 22
            },
            'tinc-tcp' => {
              'port' => 655,
              'proto' => 'tcp'
            },
            'tinc-udp' => {
              'port' => 655,
              'proto' => 'udp'
            }
          }
        }
      }
    
      @host.addresses.each do |address|
        address.list_ips.each do |ip|
          rules[ip] = {
            'interface' => 'eth0',
            'services' => {}
          }
        
          if guest = @host.guests.where(external_address: ip).first
            rules[ip]['nat'] = guest.private_address
          
            services = guest.services.where(public_service: true).to_a
            services.each do |service|
              rules[ip]['services']["#{service.kind}"] ||= {}
              rules[ip]['services']["#{service.kind}"]['port'] ||= []
              rules[ip]['services']["#{service.kind}"]['port'] << service.port
    
              if service.try :ssl_port and service.try :ssl_supported
                rules[ip]['services']["#{service.kind}s"] ||= {}
                rules[ip]['services']["#{service.kind}s"]['port'] ||= []
                rules[ip]['services']["#{service.kind}s"]['port'] << service.ssl_port
              end
            end
          end
        end
      end
      @rules = rules
    end
    
    def ssh_deep_inspect?
      false
    end

    def parse_ports(ports)
      if ports.class == Fixnum
        [ports]
      elsif ports.class == String
        ports.split(' ')#.map{|p| p.to_i}
      else
        ports
      end
    end

    def ip4tables_bin
      '/sbin/iptables'
    end
    
    def ip6tables_bin
      '/sbin/ip6tables'
    end

    def iptables_bin(host)
      if host.match /^\d+\.\d+\.\d+\.\d+$/
        ip4tables_bin
      else
        ip6tables_bin 
      end
    end

    def iptables_bins
      [ip4tables_bin, ip6tables_bin]
    end

    def handle_ssh(host, options)
      commands = []
      ports = options[:port]
      iptables = iptables_bin(host)
      interface = options[:interface] || 'eth0'
  
      if !ssh_deep_inspect?
        unless @ssh_init_done ||= [] and @ssh_init_done.include? iptables
          commands << "#{iptables} -N SSH_ATTACKED"
          commands << "#{iptables} -A SSH_ATTACKED -m recent --name SSH_brutes --set -j LOG --log-level 4 --log-prefix 'SSH attack: '"
          commands << "#{iptables} -A SSH_ATTACKED -j REJECT"
          @ssh_init_done << iptables
        end
      end
  
      ports.each do |port|
        if(options[:trust])
          parse_ports(options[:trust]).each do |s|
            commands << "#{iptables} -A INPUT -i #{interface} -m conntrack --ctstate NEW -p tcp -s #{s} -d #{host} --dport #{port} -j ACCEPT"
          end
        end

        if ssh_deep_inspect?
          # Capture SSH connections
          commands << "#{iptables} -A INPUT -i #{interface} -m conntrack --ctstate NEW -p tcp -d #{host} --dport #{port} -j SSH_CHECK"      
        else
          commands << "#{iptables} -A INPUT -i #{interface} -p tcp -d #{host} --dport #{port} ! --syn -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
          commands << "#{iptables} -A INPUT -i #{interface} -p tcp -d #{host} --dport #{port} --syn -m recent --name SSH_brutes --update --seconds 20 -j REJECT"
          commands << "#{iptables} -A INPUT -i #{interface} -p tcp -d #{host} --dport #{port} --syn -m recent --name sshconn --update --seconds 60 --hitcount 6 -j SSH_ATTACKED"
          commands << "#{iptables} -A INPUT -i #{interface} -p tcp -d #{host} --dport #{port} --syn -m recent --name sshconn --set"
          commands << "#{iptables} -A INPUT -i #{interface} -p tcp -d #{host} --dport #{port} --syn -j ACCEPT"
        end
    
        if(options[:nat])
           commands += nat(host, interface, port, 'tcp', options[:nat])
        end
      end
  
      commands
    end

    def nat(host, interface, port, proto, nat_host)
      iptables = iptables_bin(host)
  
      commands = []
  
      commands << "#{iptables} -t nat -A PREROUTING -i #{interface} -p #{proto}  -d #{host} --dport #{port} -j DNAT --to-destination #{nat_host}:#{port}"
      commands << "#{iptables} -t nat -A POSTROUTING -o #{interface} -p #{proto}  -d #{host} --dport #{port} -j MASQUERADE"
  
      commands
    end

    def build_commands(host, host_options, protocol, rule_options)
      options = host_options.merge rule_options
  
      if protocol == :ssh
        commands = handle_ssh(host, options)
      else
        iptables = iptables_bin(host)
        interface = options[:interface] || 'eth0'
        proto = options[:proto] || 'tcp'
    
        commands = ["#{iptables} -A INPUT -i #{interface} -m conntrack --ctstate NEW -p #{proto}"]
  
        if options[:shost] and options[:shost] != 'any'
          cmds = []
          commands.each do |c|
            cmds << "#{c} -s #{options[:shost]}"
          end
          commands = cmds
        end
  
        if options[:sport] and options[:sport] != 'any'
          cmds = []
          commands.each do |c|
            cmds << "#{c} --sport #{options[:sport]}"
          end
          commands = cmds
        end
  
        cmds = []
        commands.each do |c|
          cmds << "#{c} -d #{host}"
        end
        commands = cmds
  
        if options[:port] and options[:port] != 'any'
          cmds = []
          commands.each do |c|
            options[:port].each do |p|
              cmds << "#{c} --dport #{p}" 
            end
          end
          commands = cmds
        end

        commands.map!{|c| "#{c} -j ACCEPT"}
    
        if options[:port] and options[:nat]
          options[:port].each do |port|
            commands += nat(host, interface, port, proto, options[:nat])
          end
        end
      end
  
      commands
    end

    def stop_script(options = {})
      commands = []
      iptables_bins.each do |iptables|
        # ['-F', '-t nat -F'].each do |attrs|
        ['-F'].each do |attrs|
          commands << "#{iptables} #{attrs}"
        end
        
        if ssh_deep_inspect?
          ['-X SSH_ATTACKED', '-X SSH_CHECK'].each do |attrs|
            commands << "#{iptables} #{attrs} || echo 'Failed to run: #{iptables} #{attrs}'"
          end
        end
      end  
      commands * "\n    "
    end

    def list_script(options = {})
      commands = []
      iptables_bins.each do |iptables|
        commands << "#{iptables} -L"
      end  
      commands * "\n    "
    end

    def start_script(options = {})
      commands = []
      interfaces = []
  
      if ssh_deep_inspect?
        # Create SSH attack chains
        iptables_bins.each do |iptables|
          commands << "#{iptables} -N SSH_CHECK"
          commands << "#{iptables} -N SSH_ATTACKED"
        end
      end

      @rules.each do |host, host_options|
        host_options = host_options.clone    
        host_options.keys.each do |key|
          host_options[(key.to_sym rescue key) || key] = host_options.delete(key)    
        end
    
        interfaces << host_options[:interface] || 'eth0'
    
        if services = host_options.delete(:services)
          services.each do |protocol, config|
            parsed = if [Fixnum, String].include? config.class
              {port: parse_ports(config)}
            else        
              config.keys.each do |key|
                config[(key.to_sym rescue key) || key] = config.delete(key)  
              end
              config[:port] = parse_ports config[:port]
              config
            end
      
            commands += build_commands(host, host_options, protocol.to_sym, parsed)
          end
        end
      end
  
      if ssh_deep_inspect?
        iptables_bins.each do |iptables|
          # Define SSH_CHECK chain
          commands << "#{iptables} -A SSH_CHECK -m recent --set --name SSH"
          commands << "#{iptables} -A SSH_CHECK -m recent --update --seconds 60 --hitcount 4 --rttl --name SSH -j SSH_ATTACKED"
          # Define SSH_ATTACKED chain
          commands << "#{iptables} -A SSH_ATTACKED -j LOG --log-prefix 'SSH attack: ' --log-level 7"
          commands << "#{iptables} -A SSH_ATTACKED -j REJECT"
        end
      end
  
      interfaces.uniq.each do |interface|
        iptables_bins.each do |iptables|
          %w(tcp udp).each do |proto|
            commands << "#{iptables} -A INPUT -i #{interface} -m conntrack --ctstate NEW -p #{proto} -j REJECT"
          end 
        end
    
        # Block ICMP timestamp requests on IPv4
        commands << "#{ip4tables_bin} -A INPUT -i #{interface} -p icmp --icmp-type timestamp-request -j DROP"
        commands << "#{ip4tables_bin} -A OUTPUT -o #{interface} -p icmp --icmp-type timestamp-reply -j DROP"
      end
  
      commands * "\n    "
    end
    
    def init_script      
      render("/cloud_model/host/etc/init.d/cloudmodel", firewall_worker: self)
    end
    
    def write_init_script options = {root: ''}
      root = options[:root] || ''
      mkdir_p "#{root}/etc/init.d/"
      @host.ssh_connection.sftp.file.open("#{root}/etc/init.d/cloudmodel", 'w', 0700) do |f|
        f.puts init_script
      end
    end
  end
end