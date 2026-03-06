class SandboxPolicy < ApplicationPolicy
  def index?                 = true
  def show?                  = owner_only?
  def create?                = true
  def update?                = true
  def destroy?               = owner_or_admin?
  def start?                 = owner_or_admin?
  def stop?                  = owner_or_admin?
  def retry?                 = owner_only?
  def logs?                  = owner_or_admin?
  def stats?                 = owner_or_admin?
  def card?                  = owner_only?
  def connect?               = owner_only?
  def snapshot?              = owner_only?
  def restore?               = owner_only?
  def archive_restore?       = owner_or_admin?
  def purge?                 = admin?
  def tailscale_connect?     = owner_only?
  def tailscale_disconnect?  = owner_only?

  private

  def owner_only?
    record.user_id == user.id
  end

  def owner_or_admin?
    admin? || record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user:).active
    end
  end
end
