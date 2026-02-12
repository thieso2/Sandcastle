class SettingPolicy < ApplicationPolicy
  def edit?    = admin?
  def update?  = admin?
end
