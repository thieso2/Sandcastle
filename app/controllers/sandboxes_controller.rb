class SandboxesController < ApplicationController
  before_action :set_sandbox

  def destroy
    SandboxManager.new.destroy(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandcastle #{@sandbox.name} destroyed"
  end

  def start
    SandboxManager.new.start(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandcastle #{@sandbox.name} started"
  end

  def stop
    SandboxManager.new.stop(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandcastle #{@sandbox.name} stopped"
  end

  private

  def set_sandbox
    @sandbox = policy_scope(Sandbox).find(params[:id])
    authorize @sandbox
  end
end
