class ProjectPolicy < ApplicationPolicy
  def index? = true
  def show? = owner_only?
  def create? = true
  def update? = owner_only?
  def destroy? = owner_only?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user:)
    end
  end

  private

  def owner_only?
    record.user_id == user.id
  end
end
