class SnapshotPolicy < ApplicationPolicy
  def index?   = true
  def create?  = true
  def show?    = owner_or_admin?
  def destroy? = owner_or_admin?

  private

  def owner_or_admin?
    admin? || record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if admin?
        scope.all
      else
        scope.where(user:)
      end
    end
  end
end
