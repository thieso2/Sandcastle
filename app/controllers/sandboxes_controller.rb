class SandboxesController < ApplicationController
  before_action :set_sandbox

  def destroy
    SandboxManager.new.destroy(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandbox #{@sandbox.name} destroyed"
  end

  def start
    SandboxManager.new.start(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandbox #{@sandbox.name} started"
  end

  def stop
    SandboxManager.new.stop(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandbox #{@sandbox.name} stopped"
  end

  private

  def set_sandbox
    @sandbox = if Current.user.admin?
      Sandbox.active.find(params[:id])
    else
      Current.user.sandboxes.active.find(params[:id])
    end
  end
end
