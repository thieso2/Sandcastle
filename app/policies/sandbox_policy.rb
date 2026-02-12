class SandboxPolicy < ApplicationPolicy
  def index?                 = true
  def show?                  = owner_or_admin?
  def create?                = true
  def update?                = true
  def destroy?               = owner_or_admin?
  def start?                 = owner_or_admin?
  def stop?                  = owner_or_admin?
  def stats?                 = owner_or_admin?
  def connect?               = owner_or_admin?
  def snapshot?              = owner_or_admin?
  def restore?               = owner_or_admin?
  def tailscale_connect?     = owner_or_admin?
  def tailscale_disconnect?  = owner_or_admin?

  private

  def owner_or_admin?
    admin? || record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if admin?
        scope.active
      else
        scope.where(user:).active
      end
    end
  end
end
