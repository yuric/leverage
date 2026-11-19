# events.xact_id is PostgreSQL's xid8, which Active Record does not know:
# without this, each process warns "unknown OID 5069" the first time it
# reads the events table's columns. Registered as a string, the type it
# falls back to anyway. Event never reads the column (ignored_columns);
# the deferred state trigger does (C7).
ActiveSupport.on_load(:active_record_postgresqladapter) do
  singleton_class.prepend(Module.new do
    def initialize_type_map(map)
      super
      map.register_type("xid8", ActiveRecord::Type::String.new)
    end
  end)
end
