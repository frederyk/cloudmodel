module CloudModel
  module Services
    class Nginx < Base
      field :port, type: Integer, default: 80
      field :ssl_supported, type: Mongoid::Boolean#, default: false
      field :ssl_only, type: Mongoid::Boolean, default: false
      field :ssl_enforce, type: Mongoid::Boolean, default: false
      field :ssl_port, type: Integer, default: 443
      belongs_to :ssl_cert, class_name: 'CloudModel::Certificate', inverse_of: :services
      
      field :passenger_supported, type: Mongoid::Boolean, default: false
      field :passenger_env, type: String, default: 'production'
      
      field :capistrano_supported, type: Mongoid::Boolean, default: false
      
      belongs_to :deploy_web_image, class_name: 'CloudModel::WebImage', inverse_of: :services
      
      field :deploy_mongodb_host, type: String
      field :deploy_mongodb_port, type: Integer, default: 27017
      field :deploy_mongodb_database, type: String
    
      field :deploy_redis_host, type: String
      field :deploy_redis_port, type: Integer, default: 6379
    
      
      def www_home
        "/var/www"
      end
      
      def www_root
        "#{www_home}/rails"
      end
      
      def used_ports
        if ssl_supported?
          if ssl_only?
            [ssl_port]
          else
            [port, ssl_port]
          end
        else
          super
        end
      end
      
      def kind
        :http
      end
    end
  end
end