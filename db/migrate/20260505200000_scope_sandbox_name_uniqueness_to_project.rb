class ScopeSandboxNameUniquenessToProject < ActiveRecord::Migration[8.0]
  # Allow one sandbox per (user, name) within each project so a user can keep
  # a "tmp" (or any name) per project without collisions. NULLS NOT DISTINCT
  # preserves the prior rule that two project-less sandboxes can't share a name.
  def change
    remove_index :sandboxes, name: "index_sandboxes_on_user_id_and_name"
    add_index :sandboxes, [ :user_id, :name, :project_name ],
      unique: true,
      nulls_not_distinct: true,
      where: "((status)::text <> ALL (ARRAY[('destroyed'::character varying)::text, ('archived'::character varying)::text]))",
      name: "index_sandboxes_on_user_id_and_name_and_project_name"
  end
end
