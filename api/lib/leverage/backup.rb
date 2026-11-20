# The daily backup and the maintainer's restore (milestone 3 plan §2.5,
# HB-1 to HB-8). Not built yet: every method answers nothing.
module Leverage
  module Backup
    LOOK_EVERY = 15 * 60
    EVERY_HOURS = 24
    KEEP = 14
    FOLDER = "/backups".freeze

    class Failed < StandardError; end
    class Refused < Failed; end

    Target = Data.define(:host, :port, :username, :password, :database) do
      def self.current(db_config = ActiveRecord::Base.connection_db_config)
        hash = db_config.configuration_hash
        new(host: hash[:host], port: hash[:port], username: hash[:username], password: hash[:password],
          database: hash[:database])
      end

      def env = {}
      def connection_args = []
      def inspect = "#<Leverage::Backup::Target #{database}>"
      alias_method :to_s, :inspect
    end

    module_function

    def due?(every_hours: EVERY_HOURS) = false
    def run(folder: FOLDER, keep: KEEP, target: nil, spawner: nil, log: nil) = nil
    def run!(folder: FOLDER, keep: KEEP, target: nil, spawner: nil) = nil
    def prune(folder, keep: KEEP) = []
    def run_loop(folder: FOLDER, keep: KEEP, every_hours: EVERY_HOURS, look_every: LOOK_EVERY, stop: -> { false },
                 sleeper: nil, log: nil, backup: self) = nil
    def restore(file, replace: false, target: nil, workspace_id: nil, spawner: nil) = nil
    def database_exists?(target) = false
    def drop_database(target, spawner: nil) = nil
  end
end
