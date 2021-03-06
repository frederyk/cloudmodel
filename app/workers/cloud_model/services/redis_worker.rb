module CloudModel
  module Services
    class RedisWorker < BaseWorker
      def write_config
        Rails.logger.debug "    Write nginx config"
        @host.ssh_connection.sftp.file.open(File.expand_path("etc/redis.conf", @guest.deploy_path), 'w') do |f|
          f.write render("/cloud_model/guest/etc/redis.conf", guest: @guest, model: @model)
        end
      end
    end
  end
end