# The restore drill's log (milestone 3 plan §5.3): fills an empty database
# with one workspace whose whole log the engine wrote, through milestone
# 2's commands only, so that the drill can compare the log before the
# backup and after the restore. It is a seeded walk (test/support/walk.rb):
# the owner and the workspace are inserted, write no event, and every
# event after them comes from Transitions.apply. Every value is made up.
#
#   bin/rails runner script/drill/seed.rb
#
# SEED picks the walk (default 7), STEPS its length (default 150). It
# refuses a database that already has an owner, because the drill's
# figures must be of this log alone.
require_relative "../../test/support/scenario"
require_relative "../../test/support/walk"

abort "seed: this database already has an owner; the drill seeds an empty one" if User.exists?

walk = Walk.new(seed: Integer(ENV.fetch("SEED", "7")), steps: Integer(ENV.fetch("STEPS", "150"))).run
events = Event.where(workspace_id: walk.workspace_id).count
abort "seed: the walk wrote no event" if events.zero?
puts "seed: workspace #{walk.workspace_id}: #{events} events, " \
     "#{Task.where(workspace_id: walk.workspace_id).count} tasks"
